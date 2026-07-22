const http = require('http');
const https = require('https');

const PORT = process.env.PORT || 3000;
const SAS_ORIGIN = 'https://sas.jt.iq';

const server = http.createServer((req, res) => {

  // CORS
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader(
    'Access-Control-Allow-Headers',
    'Content-Type, Authorization, x-sas-target'
  );
  res.setHeader(
    'Access-Control-Allow-Methods',
    'GET, POST, PUT, DELETE, OPTIONS'
  );

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    return res.end();
  }

  // فحص السيرفر
  if (req.url === '/' || req.url === '/health') {
    res.writeHead(200, {
      'Content-Type': 'application/json'
    });

    return res.end(JSON.stringify({
      ok: true,
      service: 'NetAgent SAS Proxy'
    }));
  }

  // فقط طلبات /sas/
  if (!req.url.startsWith('/sas/')) {
    res.writeHead(404, {
      'Content-Type': 'application/json'
    });

    return res.end(JSON.stringify({
      error: 'Not Found'
    }));
  }

  const sasPath = req.url.substring(4);

  const options = {
    hostname: 'sas.jt.iq',
    port: 443,
    path: sasPath,
    method: req.method,
    headers: {
      ...req.headers,
      host: 'sas.jt.iq'
    }
  };

  delete options.headers['x-sas-target'];
  delete options.headers['content-length'];

  const proxyReq = https.request(options, proxyRes => {

    const responseHeaders = { ...proxyRes.headers };

delete responseHeaders['access-control-allow-origin'];
delete responseHeaders['access-control-allow-credentials'];

responseHeaders['access-control-allow-origin'] = '*';

res.writeHead(
  proxyRes.statusCode || 500,
  responseHeaders
);

proxyRes.pipe(res);

    proxyRes.pipe(res);
  });

  proxyReq.on('error', error => {
    res.writeHead(502, {
      'Content-Type': 'application/json'
    });

    res.end(JSON.stringify({
      error: 'SAS connection failed',
      message: error.message
    }));
  });

  req.pipe(proxyReq);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`NetAgent SAS Proxy running on port ${PORT}`);
});
