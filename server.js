const http = require('http');
const https = require('https');

// WARNING: temporary workaround if some SAS servers use untrusted SSL certificates.
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const PORT = Number(process.env.PORT) || 3000;

function applyCors(req, res) {
  const requestedHeaders = req.headers['access-control-request-headers'];
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,PATCH,DELETE,OPTIONS');
  res.setHeader(
    'Access-Control-Allow-Headers',
    requestedHeaders || 'Content-Type, Authorization, Allow-Cache-Y, X-SAS-Target'
  );
}

const server = http.createServer((req, res) => {
  applyCors(req, res);

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    return res.end();
  }

  if (req.url === '/' || req.url === '/health' || req.url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    return res.end(JSON.stringify({ ok: true, service: 'NetAgent SAS Proxy' }));
  }

  if (!req.url || !req.url.startsWith('/sas/')) {
    res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' });
    return res.end(JSON.stringify({ error: 'Not Found' }));
  }

  const sasPath = req.url.substring(4); // remove /sas

  // Dynamic target from app settings.
  const targetOriginRaw = String(req.headers['x-sas-target'] || '').trim();
  if (!targetOriginRaw) {
    res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
    return res.end(JSON.stringify({ error: 'Missing X-SAS-Target' }));
  }

  const targetOrigin = targetOriginRaw.replace(/\/+$/, '');
  let targetBaseUrl;
  try {
    targetBaseUrl = new URL(targetOrigin);
  } catch (_) {
    res.writeHead(400, { 'Content-Type': 'application/json; charset=utf-8' });
    return res.end(JSON.stringify({ error: 'Invalid X-SAS-Target' }));
  }

  const headers = { ...req.headers };
  delete headers.host;
  delete headers.origin;
  delete headers.referer;
  delete headers['x-sas-target'];

  headers.host = targetBaseUrl.host;
  headers.origin = targetBaseUrl.origin;
  headers.referer = `${targetBaseUrl.origin}/admin/`;
  headers['user-agent'] = req.headers['user-agent'] || 'Mozilla/5.0';

  const upstreamClient = targetBaseUrl.protocol === 'https:' ? https : http;

  const upstream = upstreamClient.request(
    {
      protocol: targetBaseUrl.protocol,
      hostname: targetBaseUrl.hostname,
      port: targetBaseUrl.port || (targetBaseUrl.protocol === 'https:' ? 443 : 80),
      path: sasPath,
      method: req.method,
      headers,
      timeout: 30000,
    },
    (upstreamRes) => {
      const responseHeaders = { ...upstreamRes.headers };
      delete responseHeaders['access-control-allow-origin'];
      delete responseHeaders['access-control-allow-credentials'];

      Object.entries(responseHeaders).forEach(([key, value]) => {
        if (value !== undefined) {
          try {
            res.setHeader(key, value);
          } catch (_) {
            // ignore invalid upstream header
          }
        }
      });

      applyCors(req, res);
      res.writeHead(upstreamRes.statusCode || 502);
      upstreamRes.pipe(res);
    }
  );

  upstream.on('timeout', () => {
    upstream.destroy(new Error('Upstream timeout'));
  });

  upstream.on('error', (error) => {
    if (!res.headersSent) {
      applyCors(req, res);
      res.writeHead(502, { 'Content-Type': 'application/json; charset=utf-8' });
    }
    res.end(JSON.stringify({ error: 'SAS connection failed', message: error.message }));
  });

  req.pipe(upstream);
});

server.on('error', (error) => {
  if (error && error.code === 'EADDRINUSE') {
    console.error(`Port ${PORT} is already in use.`);
  } else {
    console.error(error);
  }
  process.exit(1);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`NetAgent SAS Proxy running on port ${PORT}`);
});
