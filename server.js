const express = require('express');
const cors = require('cors');
const bodyParser = require('body-parser');
const fs = require('fs');
const path = require('path');
const morgan = require('morgan');
const SSE = require('express-sse');

const app = express();
const PORT = 49152;
const STATE_FILE = path.join(__dirname, 'state.json');

const VALID_STATUSES = new Set(['idle','thinking','working','needs_approval','success','error','warning']);

// --- State Management ---
let sessions = {};
let history = [];
let approvalResolvers = {};
let sse = new SSE();
let geminiSessionCount = 0;

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
app.use(cors());
app.use(bodyParser.json());
app.use(morgan('dev'));
app.get('/stream', (req, res, next) => {
  sse.init(req, res, next);
  setTimeout(() => sse.send({ sessions, history }, 'update'), 100);
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
  sse.send({ sessions, history }, 'update');
}

// --- Routes ---
app.post('/update', (req, res) => {
  let { id, name, status, task } = req.body;

  // Validate
  if (!VALID_STATUSES.has(status)) return res.status(400).json({ error: 'Invalid status' });
  const sessionId = (typeof id === 'string' && id.trim()) ? id.trim() : 'main';
  if (name) name = String(name).slice(0, 64);
  if (task) task = String(task).slice(0, 256);

  if (!sessions[sessionId]) {
    sessions[sessionId] = { id: sessionId, name: name || sessionId, status: 'idle', task: 'Initializing...', timestamp: Date.now() };
  }

  sessions[sessionId] = {
    ...sessions[sessionId],
    ...(name && { name }),  // update name if provided
    status,
    task,
    timestamp: Date.now()
  };

  addLog(sessionId, status, task);

  // Auto-clear terminal states after a delay
  if (['success', 'error', 'warning'].includes(status)) {
    setTimeout(() => {
      if (sessions[sessionId] && sessions[sessionId].status === status) {
        if (sessionId === 'main') {
          sessions[sessionId] = { id: sessionId, name: sessions[sessionId]?.name || 'Gemini', status: 'idle', task: 'Ready', timestamp: Date.now() };
          addLog(sessionId, 'idle', 'Ready');
          // addLog already calls saveState — no extra call needed
        } else {
          delete sessions[sessionId]; // Remove sub-agents when done
          saveState(); // no addLog here, must save explicitly
        }
      }
    }, 4000);
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

// Purge stale non-main sessions left over from previous runs
Object.keys(sessions).forEach(id => {
  if (id !== 'main') {
    delete sessions[id];
  } else {
    // Reset main to idle in case it was left in a transient state
    sessions[id].status = 'idle';
    sessions[id].task = 'Ready';
  }
});
saveState();

app.listen(PORT, () => {
  console.log(`Gemini Sentinel Mission Control Bridge active on http://localhost:${PORT}`);
});
