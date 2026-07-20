const http = require('http');
const https = require('https');
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const PORT = 8787;

function cors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,PATCH,DELETE,OPTIONS');
  res.setHeader('Access-Control-Allow-Headers',
    'Content-Type, Authorization, Allow-Cache-Y, X-SAS-Target');
}

const server = http.createServer((req, res) => {
  cors(res);
  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    return res.end();
  }

  if (!req.url.startsWith('/sas/')) {
    res.writeHead(404, {'Content-Type':'text/plain; charset=utf-8'});
    return res.end('NetAgent SAS Proxy');
  }

  const targetOrigin = req.headers['x-sas-target'];
  if (!targetOrigin || !/^https?:\/\//i.test(targetOrigin)) {
    res.writeHead(400, {'Content-Type':'application/json; charset=utf-8'});
    return res.end(JSON.stringify({error:'Missing X-SAS-Target'}));
  }

  let target;
  try {
    const origin = targetOrigin.replace(/\/+$/, '');
    target = new URL(origin + req.url.substring(4)); // remove /sas
  } catch (e) {
    res.writeHead(400, {'Content-Type':'application/json; charset=utf-8'});
    return res.end(JSON.stringify({error:'Invalid SAS target'}));
  }

  const headers = {...req.headers};
  delete headers.host;
  delete headers.origin;
  delete headers.referer;
  delete headers['x-sas-target'];
  headers.host = target.host;

  const client = target.protocol === 'https:' ? https : http;
  const upstream = client.request(target, {
    method: req.method,
    headers
  }, upstreamRes => {
    cors(res);
    const responseHeaders = {...upstreamRes.headers};
    delete responseHeaders['access-control-allow-origin'];
    delete responseHeaders['access-control-allow-credentials'];
    Object.entries(responseHeaders).forEach(([k,v]) => {
      if (v !== undefined) {
        try { res.setHeader(k, v); } catch (_) {}
      }
    });
    cors(res);
    res.writeHead(upstreamRes.statusCode || 502);
    upstreamRes.pipe(res);
  });

  upstream.on('error', err => {
    if (!res.headersSent) {
      cors(res);
      res.writeHead(502, {'Content-Type':'application/json; charset=utf-8'});
    }
    res.end(JSON.stringify({error:'SAS upstream failed', detail:err.message}));
  });

  req.pipe(upstream);
});

server.on('error', err => {
  if (err && err.code === 'EADDRINUSE') {
    console.error(`Port ${PORT} is already in use. The NetAgent proxy may already be running.`);
  } else {
    console.error(err);
  }
  process.exit(1);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`NetAgent SAS Proxy running on http://localhost:${PORT}`);
});
