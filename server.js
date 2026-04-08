const express = require('express');
const fs = require('fs');
const path = require('path');
const morgan = require('morgan');

const app = express();
const PORT = 49152;
const STATE_FILE = path.join(__dirname, 'state.json');

const VALID_STATUSES = new Set(['idle','thinking','working','needs_approval','success','error','warning']);
const PERSISTENT_SESSIONS = new Set(['main', 'claude']);

// SSE heartbeat interval (ms) — keeps WKWebView / browser connections alive
const SSE_HEARTBEAT_MS = 15000;

// --- State Management ---
let sessions = {};
let history = [];
let approvalResolvers = {};
let geminiSessionCount = 0;

// Monotonic version counter — each state mutation bumps this.
// Auto-clear timers capture the version at creation time and only fire
// if the version still matches, preventing stale timers from clearing
// legitimately new state.
let globalVersion = 0;

// Debounce timers for terminal statuses (success/error/warning).
// When a Stop/AfterAgent hook sends a terminal status, we delay applying it.
// If a new active status (working/thinking) arrives before the timer fires,
// we cancel the pending terminal — this prevents the mascot from flashing
// idle between tool calls within the same response.
const pendingTerminal = {};  // sessionId → { timer, status, task, name }

// --- Manual SSE (replaces express-sse) ---
const sseClients = new Set();

function sseBroadcast(data, event = 'update') {
  const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  for (const res of sseClients) {
    if (!res.writableEnded) {
      res.write(payload);
    } else {
      sseClients.delete(res);
    }
  }
}

// --- Load State ---
function loadState() {
  try {
    if (fs.existsSync(STATE_FILE)) {
      const data = fs.readFileSync(STATE_FILE);
      const parsed = JSON.parse(data);
      sessions = parsed.sessions || { 'main': { id: 'main', name: 'Gemini', status: 'idle', task: 'Ready', timestamp: Date.now() } };
      history = parsed.history || [];
      if (history.length > 20) history = history.slice(0, 20);
      console.log(`[State] Loaded state from ${STATE_FILE}`);
    } else {
      console.log(`[State] ${STATE_FILE} not found, initializing default state.`);
      sessions = { 'main': { id: 'main', name: 'Gemini', status: 'idle', task: 'Ready', timestamp: Date.now() } };
      history = [{ id: 'main', name: 'Gemini', status: 'idle', task: 'System Ready', time: new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }) }];
    }
  } catch (error) {
    console.error(`[State] Error loading state: ${error.message}. Initializing default state.`);
    sessions = { 'main': { id: 'main', name: 'Gemini', status: 'idle', task: 'Ready', timestamp: Date.now() } };
    history = [{ id: 'main', name: 'Gemini', status: 'idle', task: 'System Ready', time: new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }) }];
  }
}

// Coalesced async write — multiple calls within the same tick produce one write
let _saveScheduled = false;
function saveState() {
  if (_saveScheduled) return;
  _saveScheduled = true;
  setImmediate(() => {
    _saveScheduled = false;
    fs.writeFile(STATE_FILE, JSON.stringify({ sessions, history }, null, 2), (err) => {
      if (err) console.error('[State] Error saving state:', err.message);
    });
  });
}

// --- Middlewares ---
app.use(express.json());
app.use(morgan('dev'));

// Serve static files (HTML, SVGs) so WKWebView can load from http://localhost
// instead of file:// — avoids CORS/caching issues with EventSource and fetch.
app.use(express.static(__dirname));

app.get('/stream', (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    'Connection': 'keep-alive',
  });
  res.write('\n'); // flush headers

  sseClients.add(res);

  // Send current state to newly connected client
  const initial = `event: update\ndata: ${JSON.stringify({ sessions, history })}\n\n`;
  setTimeout(() => {
    if (!res.writableEnded) res.write(initial);
  }, 50);

  // Heartbeat — send a comment line every 15s to keep the connection alive.
  const heartbeat = setInterval(() => {
    if (!res.writableEnded) {
      res.write(':heartbeat\n\n');
    }
  }, SSE_HEARTBEAT_MS);

  req.on('close', () => {
    clearInterval(heartbeat);
    sseClients.delete(res);
  });
});

// --- Helper Functions ---
function addLog(id, status, task) {
  const session = sessions[id] || { name: id };
  history.unshift({
    id,
    name: session.name || id,
    status,
    task,
    time: new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
  });
  if (history.length > 20) history.pop();
  saveState();
  sseBroadcast({ sessions, history });
}

// --- Routes ---
app.post('/update', (req, res) => {
  let { id, name, status, task } = req.body;

  // Debug: log every update request
  console.log(`[UPDATE] id=${id} status=${status} task=${task} | current=${sessions[(typeof id === 'string' && id.trim()) ? id.trim() : 'main']?.status}`);

  // Validate
  if (!VALID_STATUSES.has(status)) return res.status(400).json({ error: 'Invalid status' });
  const sessionId = (typeof id === 'string' && id.trim()) ? id.trim() : 'main';
  if (name) name = String(name).slice(0, 64);
  if (task) task = String(task).slice(0, 256);

  if (!sessions[sessionId]) {
    sessions[sessionId] = { id: sessionId, name: name || sessionId, status: 'idle', task: 'Initializing...', timestamp: Date.now() };
  }

  // Don't let hooks overwrite needs_approval — only /action (approve/deny)
  // or the timeout can clear it. This prevents the Stop hook from stomping
  // on a pending approval prompt.
  if (sessions[sessionId].status === 'needs_approval' && status !== 'needs_approval' && approvalResolvers[sessionId]) {
    return res.json({ success: true, ignored: true });
  }

  const ACTIVE_STATES = new Set(['working', 'thinking']);
  const TERMINAL_STATES = new Set(['success', 'error', 'warning']);

  // When an active status arrives, cancel any pending terminal debounce —
  // the agent is still working, so a previous Stop/AfterAgent was premature.
  if (ACTIVE_STATES.has(status) && pendingTerminal[sessionId]) {
    clearTimeout(pendingTerminal[sessionId].timer);
    delete pendingTerminal[sessionId];
  }

  // Debounce terminal statuses: don't apply immediately when the session is
  // active. Instead, wait a short period — if a new PreToolUse (working)
  // arrives before the timer fires, the terminal is cancelled. This prevents
  // the mascot from flashing idle between tool calls in the same response.
  if (ACTIVE_STATES.has(sessions[sessionId].status) && TERMINAL_STATES.has(status)) {
    // Cancel any existing pending terminal for this session
    if (pendingTerminal[sessionId]) {
      clearTimeout(pendingTerminal[sessionId].timer);
    }
    const DEBOUNCE_MS = 1000; // 5s — spans the gap between tool calls without feeling sluggish
    pendingTerminal[sessionId] = {
      status, task, name,
      timer: setTimeout(() => {
        delete pendingTerminal[sessionId];
        if (!sessions[sessionId]) return; // session was deleted during debounce
        sessions[sessionId] = {
          ...sessions[sessionId],
          ...(name && { name }),
          status,
          task,
          timestamp: Date.now(),
          _v: ++globalVersion
        };
        addLog(sessionId, status, task);

        // Auto-clear to idle after terminal state
        const capturedVersion = sessions[sessionId]._v;
        const clearDelay = PERSISTENT_SESSIONS.has(sessionId) ? 8000 : 4000;
        setTimeout(() => {
          if (sessions[sessionId] && sessions[sessionId]._v === capturedVersion) {
            if (PERSISTENT_SESSIONS.has(sessionId)) {
              sessions[sessionId] = { id: sessionId, name: sessions[sessionId]?.name || sessionId, status: 'idle', task: 'Ready', timestamp: Date.now(), _v: ++globalVersion };
              addLog(sessionId, 'idle', 'Ready');
            } else {
              delete sessions[sessionId];
              saveState();
            }
          }
        }, clearDelay);
      }, DEBOUNCE_MS)
    };
    console.log(`[DEBOUNCE] ${sessionId}: ${status} debounced for 3s (current=${sessions[sessionId].status})`);
    return res.json({ success: true, debounced: true });
  }

  sessions[sessionId] = {
    ...sessions[sessionId],
    ...(name && { name }),  // update name if provided
    status,
    task,
    timestamp: Date.now(),
    _v: ++globalVersion
  };

  addLog(sessionId, status, task);

  // Auto-clear terminal states after a delay.
  // Persistent sessions (main, claude) reset to idle; ephemeral ones are deleted.
  // The captured version ensures stale timers from a previous work cycle
  // never clear a legitimately new terminal state.
  if (['success', 'error', 'warning'].includes(status)) {
    const capturedVersion = sessions[sessionId]._v;
    const clearDelay = PERSISTENT_SESSIONS.has(sessionId) ? 8000 : 4000;
    setTimeout(() => {
      if (sessions[sessionId] && sessions[sessionId]._v === capturedVersion) {
        if (PERSISTENT_SESSIONS.has(sessionId)) {
          sessions[sessionId] = { id: sessionId, name: sessions[sessionId]?.name || sessionId, status: 'idle', task: 'Ready', timestamp: Date.now(), _v: ++globalVersion };
          addLog(sessionId, 'idle', 'Ready');
        } else {
          delete sessions[sessionId]; // Remove ephemeral sub-agents when done
          saveState();
        }
      }
    }, clearDelay);
  }
  res.json({ success: true });
});

app.get('/wait-approval', (req, res) => {
  const sessionId = req.query.id || 'main';

  if (approvalResolvers[sessionId]) {
      return res.status(409).json({ error: 'Already waiting for approval for this session.' });
  }

  console.log(`[Gemini] Waiting for user approval for session: ${sessionId}`);

  // Set a timeout for approval
  const timeout = setTimeout(() => {
    if (approvalResolvers[sessionId]) {
      console.log(`[Gemini] Timeout waiting for approval for session: ${sessionId}`);
      const deniedTask = 'Approval timed out.';
      sessions[sessionId] = { ...sessions[sessionId], status: 'warning', task: deniedTask, timestamp: Date.now() };
      approvalResolvers[sessionId]('timeout');
      delete approvalResolvers[sessionId];
      addLog(sessionId, 'warning', deniedTask);
    }
  }, 30000); // 30 seconds timeout

  approvalResolvers[sessionId] = (action) => {
    clearTimeout(timeout);
    if (!res.headersSent) res.json({ action });
  };

  res.on('close', () => {
    if (approvalResolvers[sessionId]) {
      console.log(`[Gemini] Connection closed while waiting for approval for session: ${sessionId}. Cleaning up.`);
      clearTimeout(timeout);
      delete approvalResolvers[sessionId];
      if (sessions[sessionId]) {
          sessions[sessionId].status = 'warning';
          sessions[sessionId].task = 'Connection lost during wait.';
          addLog(sessionId, 'warning', 'Connection lost during wait.');
      }
    }
  });
});

app.delete('/session/:id', (req, res) => {
  const sessionId = req.params.id;
  if (sessions[sessionId]) {
    delete sessions[sessionId];
    saveState();
    sseBroadcast({ sessions, history });
    return res.json({ success: true });
  }
  res.status(404).json({ error: 'Session not found' });
});

app.get('/state', (req, res) => {
  res.json({ sessions, history });
});

app.post('/action', (req, res) => {
  const { id, action } = req.body;
  const sessionId = id || 'main';

  if (!sessions[sessionId]) {
      return res.status(404).json({ error: `Session ${sessionId} not found.` });
  }

  if (approvalResolvers[sessionId]) {
    let logTask = `User ${action} request.`;
    let newStatus = sessions[sessionId].status;

    if (action === 'approve') {
        logTask = `Approved! Resuming: ${sessions[sessionId].pendingTask || 'Task'}`;
        newStatus = 'working';
    } else {
        logTask = `Request Denied.`;
        newStatus = 'warning';
    }

    sessions[sessionId] = {
      ...sessions[sessionId],
      status: newStatus,
      task: logTask,
      timestamp: Date.now()
    };

    approvalResolvers[sessionId](action);
    delete approvalResolvers[sessionId];
    addLog(sessionId, newStatus, logTask);
  } else {
      addLog(sessionId, 'warning', `UI action received with no pending approval: ${action}`);
  }

  res.json({ success: true });
});

app.post('/session-start', (req, res) => {
  geminiSessionCount++;
  console.log(`[Session] Gemini session opened. Active sessions: ${geminiSessionCount}`);
  res.json({ success: true, count: geminiSessionCount });
});

app.post('/session-end', (req, res) => {
  geminiSessionCount = Math.max(0, geminiSessionCount - 1);
  console.log(`[Session] Gemini session closed. Active sessions: ${geminiSessionCount}`);
  if (geminiSessionCount === 0) {
    console.log('[Session] Last session closed. Shutting down.');
    res.json({ success: true, count: 0, shutdown: true });
    setTimeout(() => process.exit(0), 500);
  } else {
    res.json({ success: true, count: geminiSessionCount });
  }
});

// --- Initialization ---
loadState();

// Purge stale sessions left over from previous runs.
// Persistent sessions (main, claude) are reset to idle; all others are deleted.
Object.keys(sessions).forEach(id => {
  if (PERSISTENT_SESSIONS.has(id)) {
    sessions[id].status = 'idle';
    sessions[id].task = 'Ready';
    sessions[id]._v = ++globalVersion;
  } else {
    delete sessions[id];
  }
});
saveState();

// Catch JSON parse errors from body-parser so they don't crash the server
app.use((err, req, res, next) => {
  if (err.type === 'entity.parse.failed') {
    console.warn(`[Server] Bad JSON from ${req.method} ${req.path}: ${err.message}`);
    return res.status(400).json({ error: 'Invalid JSON' });
  }
  next(err);
});

app.listen(PORT, () => {
  console.log(`Gemini Sentinel Mission Control Bridge active on http://localhost:${PORT}`);
});
