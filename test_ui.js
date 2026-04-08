// Test: verify the index.html UI correctly renders needs_approval state
// Uses a lightweight DOM check — fetches /state, simulates what renderSessions does,
// and verifies the approval buttons would be visible.

const http = require('http');

const SERVER = 'http://localhost:49152';

function fetch(url, opts = {}) {
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const req = http.request({
      hostname: u.hostname,
      port: u.port,
      path: u.pathname + u.search,
      method: opts.method || 'GET',
      headers: opts.headers || {},
    }, res => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => resolve({ status: res.statusCode, body: data }));
    });
    req.on('error', reject);
    if (opts.body) req.write(opts.body);
    req.end();
  });
}

async function test() {
  console.log('=== UI Rendering Test ===\n');

  const SESSION = 'ui-test-' + Date.now();

  // 1. Set up needs_approval
  console.log('1. Creating needs_approval session...');
  await fetch(`${SERVER}/update`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: SESSION, name: 'UITest', status: 'needs_approval', task: 'Test render' }),
  });

  // 2. Start long-poll so it doesn't get overwritten
  const waitPromise = fetch(`${SERVER}/wait-approval?id=${SESSION}`);

  // 3. Read index.html source and check CSS rules
  const { body: html } = await fetch(`${SERVER}/index.html`);

  // Check: CSS rule .s-needs_approval .approval-btns { display: flex; }
  const hasApprovalCSS = html.includes('.s-needs_approval .approval-btns');
  console.log(`2. CSS rule for .s-needs_approval .approval-btns exists: ${hasApprovalCSS ? 'OK' : 'FAIL'}`);

  // Check: approval buttons exist in template
  const hasAllowBtn = html.includes('abtn-allow');
  const hasDenyBtn = html.includes('abtn-deny');
  console.log(`3. ALLOW button in template: ${hasAllowBtn ? 'OK' : 'FAIL'}`);
  console.log(`4. DENY button in template: ${hasDenyBtn ? 'OK' : 'FAIL'}`);

  // Check: sendAction function posts to /action
  const hasSendAction = html.includes("fetch('/action'") || html.includes('fetch(\'/action\'');
  console.log(`5. sendAction posts to /action: ${hasSendAction ? 'OK' : 'FAIL'}`);

  // Check: updateSlot sets className to s-${status}
  const hasUpdateSlot = html.includes('`mascot-slot s-${s.status}`');
  console.log(`6. updateSlot sets s-needs_approval class: ${hasUpdateSlot ? 'OK' : 'FAIL'}`);

  // Check: thought bubble visibility tied to needs_approval
  const hasThoughtBubbleCSS = html.includes('.s-needs_approval .thought-bubble');
  console.log(`7. Thought bubble shows on needs_approval: ${hasThoughtBubbleCSS ? 'OK' : 'FAIL'}`);

  // Check: default display of approval-btns is none (hidden by default)
  const btnDefaultHidden = html.includes('.approval-btns') && html.includes('display: none') || html.includes('display:none');
  console.log(`8. Approval buttons hidden by default: ${btnDefaultHidden ? 'OK' : 'CHECK MANUALLY'}`);

  // Check: polling or SSE is set up
  const hasSSE = html.includes('EventSource');
  const hasPolling = html.includes('setInterval');
  console.log(`9. SSE connection: ${hasSSE ? 'OK' : 'MISSING'}`);
  console.log(`10. Polling fallback: ${hasPolling ? 'OK' : 'MISSING'}`);

  // Check: the sendAction URL uses relative path (same-origin)
  const usesRelativeAction = html.includes("'/action'");
  const usesAbsoluteAction = html.includes("'http://localhost:49152/action'");
  console.log(`11. Action URL is relative (same-origin): ${usesRelativeAction ? 'OK' : usesAbsoluteAction ? 'USES ABSOLUTE' : 'FAIL'}`);

  // Check: the SSE/fetch URLs use relative paths
  const usesRelativeStream = html.includes("'/stream'");
  const usesRelativeState = html.includes("'/state'");
  console.log(`12. Stream URL is relative: ${usesRelativeStream ? 'OK' : 'FAIL'}`);
  console.log(`13. State URL is relative: ${usesRelativeState ? 'OK' : 'FAIL'}`);

  // Clean up
  await fetch(`${SERVER}/action`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: SESSION, action: 'deny' }),
  });
  await waitPromise;

  console.log('\n=== UI Test Complete ===');
}

test().catch(err => {
  console.error('Test error:', err.message);
  process.exit(1);
});
