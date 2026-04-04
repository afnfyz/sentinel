const express = require('express');
const cors = require('cors');
const bodyParser = require('body-parser');
const fs = require('fs');
const morgan = require('morgan');
const SSE = require('express-sse');

const app = express();
const PORT = 49152;
const STATE_FILE = 'state.json';

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

function saveState() {
  try {
    fs.writeFileSync(STATE_FILE, JSON.stringify({ sessions, history }, null, 2));
  } catch (error) {
    console.error('[State] Error saving state:', error.message);
  }
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
  const { id, status, task } = req.body;
  const sessionId = id || 'main';
  
  if (!sessions[sessionId]) {
    sessions[sessionId] = { id: sessionId, name: sessionId, status: 'idle', task: 'Initializing...', timestamp: Date.now() };
  }

  sessions[sessionId] = {
    ...sessions[sessionId], // Preserve existing session properties
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
          sessions[sessionId] = { id: sessionId, name: sessionId, status: 'idle', task: 'Ready', timestamp: Date.now() };
        } else {
          delete sessions[sessionId]; // Remove sub-agents when done
        }
        addLog(sessionId, sessions[sessionId].status, sessions[sessionId].task);
        saveState();
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
      addLog(sessionId, 'warning', deniedTask);
      sessions[sessionId] = { ...sessions[sessionId], status: 'warning', task: deniedTask, timestamp: Date.now() };
      approvalResolvers[sessionId]('timeout');
      delete approvalResolvers[sessionId];
      saveState();
    }
  }, 30000); // 30 seconds timeout

  approvalResolvers[sessionId] = (action) => {
    clearTimeout(timeout);
    res.json({ action });
  };

  res.on('close', () => {
    if (approvalResolvers[sessionId]) {
      console.log(`[Gemini] Connection closed while waiting for approval for session: ${sessionId}. Cleaning up.`);
      clearTimeout(timeout);
      delete approvalResolvers[sessionId];
      // Update session to indicate disconnection or waiting state if appropriate
      if (sessions[sessionId]) {
          sessions[sessionId].status = 'warning'; // Or a new 'disconnected' status
          sessions[sessionId].task = 'Connection lost during wait.';
          addLog(sessionId, sessions[sessionId].status, sessions[sessionId].task);
          saveState();
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
    let newStatus = sessions[sessionId].status; // Keep current status by default

    if (action === 'approve') {
        logTask = `Approved! Resuming: ${sessions[sessionId].pendingTask || 'Task'}`;
        newStatus = 'working'; // Move to working after approval
    } else { // Deny
        logTask = `Request Denied.`;
        newStatus = 'warning'; // Set to warning on denial
    }
    
    sessions[sessionId] = { 
      ...sessions[sessionId], 
      status: newStatus, 
      task: logTask, 
      timestamp: Date.now() 
    };
    
    addLog(sessionId, newStatus, logTask);
    approvalResolvers[sessionId](action);
    delete approvalResolvers[sessionId];
    saveState();
  } else {
      addLog(sessionId, 'info', `UI action received: ${action}`);
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
app.listen(PORT, () => {
  console.log(`Gemini Sentinel Mission Control Bridge active on http://localhost:${PORT}`);
});
