const http = require('http');
const cp = require('child_process');

const PORT = 3097;
const env = {
  ...process.env,
  PORT: String(PORT),
  ALLOW_INSECURE_TLS: '1',
  NODE_ENV: 'production',
};

const srv = cp.spawn(process.execPath, ['../server.js'], {
  cwd: __dirname,
  env,
  stdio: ['ignore', 'pipe', 'pipe'],
});
srv.stdout.on('data', (d) => process.stdout.write(d));
srv.stderr.on('data', (d) => process.stderr.write(d));

function doReq(method, path, headers, body, cb) {
  const buf = body ? Buffer.from(body) : Buffer.alloc(0);
  const r = http.request(
    { hostname: '127.0.0.1', port: PORT, path, method, headers: { ...headers, 'content-length': buf.length } },
    (res) => {
      let b = '';
      res.on('data', (d) => (b += d));
      res.on('end', () => cb(null, res.statusCode, b));
    }
  );
  r.on('error', (e) => cb(e));
  if (buf.length) r.write(buf);
  r.end();
}

setTimeout(() => {
  doReq('GET', '/health', {}, '', (e, s, b) => {
    console.log('1) health:', s, JSON.parse(b).ok);

    doReq('GET', '/ping-target?target=https://sas.speednet-iq.com', {}, '', (e2, s2, b2) => {
      const r = JSON.parse(b2);
      console.log('2) ping-target:', s2, 'ok=' + r.ok, 'latency=' + r.latencyMs + 'ms', r.error || '');

      const h = { 'content-type': 'application/json', 'x-sas-target': 'https://sas.speednet-iq.com' };
      doReq('POST', '/sas/admin/api/index.php/api/login', h, '{"payload":"test"}', (e3, s3, b3) => {
        console.log('3) login via proxy:', s3, b3.slice(0, 200));
        srv.kill();
        process.exit(0);
      });
    });
  });
}, 900);
