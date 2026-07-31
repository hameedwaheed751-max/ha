const http = require('http');
const { spawn } = require('child_process');

function startProxy(env) {
  return spawn(process.execPath, ['server.js'], {
    cwd: process.cwd(),
    env: { ...process.env, ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function requestOnce(port, path, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ hostname: '127.0.0.1', port, path, method: 'GET', headers }, (res) => {
      let body = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body, headers: res.headers }));
    });
    req.on('error', reject);
    req.end();
  });
}

(async () => {
  const proxy = startProxy({ PORT: '3121', ALLOW_HTTP_TARGETS: '1', ALLOW_PRIVATE_TARGETS: '1', ALLOW_INSECURE_TLS: '1' });
  proxy.stdout.on('data', (d) => process.stdout.write(d));
  proxy.stderr.on('data', (d) => process.stdout.write(d));

  await new Promise((resolve) => setTimeout(resolve, 1200));
  const health = await requestOnce(3121, '/health');
  console.log('health', health.status, health.body.includes('NetAgent SAS Proxy'));
  const missingTarget = await requestOnce(3121, '/login');
  console.log('missingTarget', missingTarget.status, missingTarget.body.includes('Missing SAS target'));
  proxy.kill();
})();
