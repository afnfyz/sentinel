const http = require('http');

const PORT = 49152;
const BASE_URL = `http://localhost:${PORT}`;

async function request(path, method = 'GET', body = null) {
  return new Promise((resolve, reject) => {
    const options = {
      hostname: 'localhost',
      port: PORT,
      path: path,
      method: method,
      headers: {
        'Content-Type': 'application/json'
      }
    };

    const req = http.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => data += chunk);
      res.on('end', () => {
        try {
          resolve({
            statusCode: res.statusCode,
            body: data ? JSON.parse(data) : null
          });
        } catch (e) {
          resolve({
            statusCode: res.statusCode,
            body: data
          });
        }
      });
    });

    req.on('error', (e) => reject(e));
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

async function runTests() {
  console.log('--- Starting API Tests ---');

  // 1. Test /update
  console.log('Testing /update...');
  const updateRes = await request('/update', 'POST', {
    id: 'test-agent',
    name: 'Test Agent',
    status: 'working',
    task: 'Running tests'
  });
  console.log('Update result:', updateRes.statusCode === 200 ? 'SUCCESS' : 'FAILED', updateRes.body);

  // 2. Verify state
  console.log('Verifying state...');
  const stateRes = await request('/state');
  const session = stateRes.body.sessions['test-agent'];
  if (session && session.status === 'working' && session.task === 'Running tests') {
    console.log('State verification: SUCCESS');
  } else {
    console.log('State verification: FAILED', session);
  }

  // 3. Test approval flow (simulated)
  console.log('Testing approval flow...');
  // First, set state to needs_approval
  await request('/update', 'POST', {
    id: 'test-agent',
    status: 'needs_approval',
    task: 'Requesting permission'
  });

  // Start waiting for approval in the background
  const waitPromise = request('/wait-approval?id=test-agent');

  // Simulate UI action
  console.log('Simulating UI approval...');
  await request('/action', 'POST', {
    id: 'test-agent',
    action: 'approve'
  });

  const waitResult = await waitPromise;
  console.log('Wait-approval result:', waitResult.body.action === 'approve' ? 'SUCCESS' : 'FAILED', waitResult.body);

  // 4. Test session count
  console.log('Testing session start/end...');
  const startRes = await request('/session-start', 'POST');
  console.log('Session start count:', startRes.body.count);

  const endRes = await request('/session-end', 'POST');
  console.log('Session end count:', endRes.body.count);
  
  console.log('--- API Tests Completed ---');
}

runTests().catch(console.error);
