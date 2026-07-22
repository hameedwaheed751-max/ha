const http = require('http');
const https = require('https');

// WARNING: هذا يتجاوز فحص شهادة SSL (مطلوب فقط إذا شهادات SAS غير موثوقة).
process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';

const PORT = Number(process.env.PORT) || 3000;
const DEFAULT_SAS_ORIGIN = 'https://sas.speednet-iq.com';

function applyCors(req, res) {
  const requestedHeaders = req.headers['access-control-request-headers'];
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,PATCH,DELETE,OPTIONS');
  res.setHeader(
    'Access-Control-Allow-Headers',
    requestedHeaders || 'Content-Type, Authorization, Allow-Cache-Y, X-SAS-Target'
  );
}

function sendJson(res, statusCode, payload, req) {
  applyCors(req, res);
  res.writeHead(statusCode, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(payload));
}

function resolveTargetUrl(req, sasPathWithQuery) {
  const targetOriginRaw = String(req.headers['x-sas-target'] || DEFAULT_SAS_ORIGIN).trim();
  const targetOrigin = targetOriginRaw.replace(/\/+$/, '');

  const base = new URL(targetOrigin);
  const full = new URL(base.origin + sasPathWithQuery);

  return { base, full };
}

const server = http.createServer((req, res) => {
  applyCors(req, res);

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    return res.end();
  }

  if (req.url === '/' || req.url === '/health' || req.url === '/healthz') {
    return sendJson(res, 200, { ok: true, service: 'NetAgent SAS Proxy' }, req);
  }

  if (!req.url || !req.url.startsWith('/sas/')) {
    return sendJson(res, 404, { error: 'Not Found' }, req);
  }

  const sasPathWithQuery = req.url.substring(4); // remove /sas

  let target;
  try {
    target = resolveTargetUrl(req, sasPathWithQuery);
  } catch (_) {
    return sendJson(res, 400, { error: 'Invalid X-SAS-Target' }, req);
  }

  const headers = { ...req.headers };
  delete headers.host;
  delete headers.origin;
  delete headers.referer;
  delete headers['x-sas-target'];

  headers.host = target.base.host;
  headers.origin = target.base.origin;
  headers.referer = `${target.base.origin}/admin/`;
  headers['user-agent'] = req.headers['user-agent'] || 'Mozilla/5.0';

  const upstreamClient = target.full.protocol === 'https:' ? https : http;

  const upstream = upstreamClient.request(
    {
      protocol: target.full.protocol,
      hostname: target.full.hostname,
      port: target.full.port || (target.full.protocol === 'https:' ? 443 : 80),
      path: target.full.pathname + target.full.search,
      method: req.method,
      headers,
      timeout: 30000,
    },
    (upstreamRes) => {
      const responseHeaders = { ...upstreamRes.headers };
      delete responseHeaders['access-control-allow-origin'];
      delete responseHeaders['access-control-allow-credentials'];

      for (const [key, value] of Object.entries(responseHeaders)) {
        if (value !== undefined) {
          try {
            res.setHeader(key, value);
          } catch (_) {}
        }
      }

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
      return sendJson(res, 502, { error: 'SAS connection failed', message: error.message }, req);
    }
    try {
      res.end(JSON.stringify({ error: 'SAS connection failed', message: error.message }));
    } catch (_) {}
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
