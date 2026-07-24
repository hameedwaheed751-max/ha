const http = require('http');
const https = require('https');
const net = require('net');

const PORT = Number(process.env.PORT) || 3000;
const NODE_ENV = process.env.NODE_ENV || 'development';
const PROXY_TOKEN = String(process.env.PROXY_TOKEN || '').trim();
// Compatibility default: keep old behavior (skip TLS cert verification)
// unless explicitly disabled with ALLOW_INSECURE_TLS=0.
const ALLOW_INSECURE_TLS = process.env.ALLOW_INSECURE_TLS !== '0';
// Compatibility default: allow private targets unless explicitly disabled.
const ALLOW_PRIVATE_TARGETS = process.env.ALLOW_PRIVATE_TARGETS !== '0';
const TARGET_ALLOWLIST = String(process.env.SAS_TARGET_ALLOWLIST || '')
  .split(',')
  .map((item) => item.trim().toLowerCase())
  .filter(Boolean);

if (ALLOW_INSECURE_TLS) {
  // Use only when SAS uses self-signed or invalid certificates.
  // Insecure TLS is handled by the HTTPS agent rather than a global env variable.
}

const INSECURE_HTTPS_AGENT = new https.Agent({
  rejectUnauthorized: !ALLOW_INSECURE_TLS,
});

function applyCors(req, res) {
  const requestedHeaders = req.headers['access-control-request-headers'];
  const requestOrigin = String(req.headers.origin || '').trim();
  const allowOrigin = process.env.CORS_ALLOW_ORIGIN || requestOrigin || '*';
  res.setHeader('Access-Control-Allow-Origin', allowOrigin);
  if (requestOrigin) {
    res.setHeader('Access-Control-Allow-Credentials', 'true');
    res.setHeader('Vary', 'Origin');
  }
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,PATCH,DELETE,OPTIONS');
  res.setHeader(
    'Access-Control-Allow-Headers',
    requestedHeaders || 'Content-Type, Authorization, Allow-Cache-Y, X-SAS-Target, X-Proxy-Token, X-Auth-Token, X-XSRF-TOKEN'
  );
  res.setHeader('Access-Control-Max-Age', '86400');
}

function sendJson(req, res, status, payload) {
  applyCors(req, res);
  res.writeHead(status, {'Content-Type': 'application/json; charset=utf-8'});
  res.end(JSON.stringify(payload));
}

function hasValidProxyToken(req) {
  if (!PROXY_TOKEN) {
    return true;
  }
  const xToken = String(req.headers['x-proxy-token'] || '').trim();
  const auth = String(req.headers.authorization || '').trim();
  const bearer = auth.toLowerCase().startsWith('bearer ') ? auth.slice(7).trim() : '';
  return xToken === PROXY_TOKEN || bearer === PROXY_TOKEN;
}

function isPrivateIp(ip) {
  if (!ip) return true;
  if (net.isIPv4(ip)) {
    const parts = ip.split('.').map(Number);
    if (parts[0] === 10) return true;
    if (parts[0] === 127) return true;
    if (parts[0] === 0) return true;
    if (parts[0] === 169 && parts[1] === 254) return true;
    if (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) return true;
    if (parts[0] === 192 && parts[1] === 168) return true;
    return false;
  }
  if (net.isIPv6(ip)) {
    const normalized = ip.toLowerCase();
    if (normalized === '::1') return true;
    if (normalized.startsWith('fc') || normalized.startsWith('fd')) return true;
    if (normalized.startsWith('fe80')) return true;
    return false;
  }
  return true;
}

function isLocalHostname(hostname) {
  const host = String(hostname || '').toLowerCase();
  return host === 'localhost' || host.endsWith('.localhost');
}

function hostAllowedByAllowlist(hostname) {
  if (TARGET_ALLOWLIST.length === 0) return true;
  const host = String(hostname || '').toLowerCase();
  return TARGET_ALLOWLIST.some((rule) => {
    if (rule.startsWith('*.')) {
      const suffix = rule.slice(1); // keep leading dot
      return host.endsWith(suffix);
    }
    return host === rule;
  });
}

function validateTarget(targetBaseUrl) {
  if (!['http:', 'https:'].includes(targetBaseUrl.protocol)) {
    return 'Only http/https targets are allowed';
  }

  const hostname = targetBaseUrl.hostname;
  if (!hostname) {
    return 'Target host is required';
  }

  if (isLocalHostname(hostname)) {
    return 'Localhost targets are not allowed';
  }

  const parsedIp = net.isIP(hostname) ? hostname : null;
  if (!ALLOW_PRIVATE_TARGETS && parsedIp && isPrivateIp(parsedIp)) {
    return 'Private IP targets are not allowed';
  }

  if (!hostAllowedByAllowlist(hostname)) {
    return 'Target host is not in SAS_TARGET_ALLOWLIST';
  }

  return null;
}

function buildUpstreamHeaders(req) {
  // Forward browser-origin headers only, but strip proxy/internal metadata.
  const headers = {...req.headers};
  delete headers.host;
  delete headers.origin;
  delete headers.referer;
  delete headers['x-sas-target'];
  delete headers['x-proxy-token'];

  const proxyHeaders = [
    'x-forwarded-for',
    'x-forwarded-host',
    'x-forwarded-proto',
    'x-real-ip',
    'x-request-start',
    'x-railway-edge',
    'x-railway-request-id',
    'x-proxy-via',
    'via',
    'forwarded',
    'cf-connecting-ip',
    'cf-ray',
    'cf-ipcountry',
  ];
  for (const headerName of proxyHeaders) {
    delete headers[headerName];
  }

  if (!headers['user-agent']) {
    headers['user-agent'] = 'NetAgent-SAS-Proxy/1.0';
  }

  return headers;
}

function filterResponseHeaders(upstreamHeaders) {
  const hopByHop = new Set([
    'connection',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailers',
    'transfer-encoding',
    'upgrade',
    'access-control-allow-origin',
    'access-control-allow-credentials',
  ]);

  const out = {};
  for (const [key, value] of Object.entries(upstreamHeaders || {})) {
    if (!hopByHop.has(String(key).toLowerCase()) && value !== undefined) {
      out[key] = value;
    }
  }
  return out;
}

function handleRequest(req, res) {
  applyCors(req, res);

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  if (req.url === '/' || req.url === '/health' || req.url === '/healthz') {
    sendJson(req, res, 200, {
      ok: true,
      service: 'NetAgent SAS Proxy',
      env: NODE_ENV,
      allowInsecureTls: ALLOW_INSECURE_TLS,
      hasTokenAuth: Boolean(PROXY_TOKEN),
      hasAllowlist: TARGET_ALLOWLIST.length > 0,
    });
    return;
  }

  if (!hasValidProxyToken(req)) {
    sendJson(req, res, 401, {error: 'Unauthorized'});
    return;
  }

  if (!req.url || !req.url.startsWith('/sas/')) {
    sendJson(req, res, 404, {error: 'Not Found'});
    return;
  }

  const reqUrl = new URL(req.url, 'http://localhost');
  const sasPath = reqUrl.pathname.substring(4) + reqUrl.search;
  const targetOriginRaw = String(req.headers['x-sas-target'] || '').trim();
  if (!targetOriginRaw) {
    sendJson(req, res, 400, {error: 'Missing X-SAS-Target'});
    return;
  }

  const targetOrigin = targetOriginRaw.replace(/\/+$/, '');
  let targetBaseUrl;
  try {
    targetBaseUrl = new URL(targetOrigin);
  } catch (_) {
    sendJson(req, res, 400, {error: 'Invalid X-SAS-Target'});
    return;
  }

  const targetError = validateTarget(targetBaseUrl);
  if (targetError) {
    sendJson(req, res, 403, {error: targetError});
    return;
  }

  const upstreamClient = targetBaseUrl.protocol === 'https:' ? https : http;
  const upstreamHeaders = buildUpstreamHeaders(req);

  // Preserve browser-origin headers for sas.jt.iq and fill missing values
  // with the same origin defaults from the HAR login request.
  if (String(targetBaseUrl.hostname || '').toLowerCase() === 'sas.jt.iq') {
    const targetOrigin = targetBaseUrl.origin;
    const defaultBrowserHeaders = {
      origin: targetOrigin,
      referer: `${targetOrigin}/`,
      'accept': 'application/json, text/plain, */*',
      'accept-language': 'ar,en-US;q=0.9,en;q=0.8',
      'accept-encoding': 'gzip, deflate, br, zstd',
      'allow-cache-y': 'yes',
      'sec-fetch-site': 'same-origin',
      'sec-fetch-mode': 'cors',
      'sec-fetch-dest': 'empty',
      'sec-fetch-user': '?0',
      'sec-ch-ua': '"Not;A=Brand";v="8", "Chromium";v="150", "Google Chrome";v="150"',
      'sec-ch-ua-mobile': '?0',
      'sec-ch-ua-platform': '"Windows"',
      priority: 'u=1, i',
    };

    for (const [headerName, defaultValue] of Object.entries(defaultBrowserHeaders)) {
      upstreamHeaders[headerName] = req.headers[headerName] || defaultValue;
    }

    if (req.headers.cookie) {
      upstreamHeaders.cookie = req.headers.cookie;
    }
  }

  // Ensure upstream Host and a realistic User-Agent are set; some SAS hosts
  // block requests with missing/strange Host or UA (WAF). Also prefer JSON
  // Accept when absent to hint the API response format.
  try {
    upstreamHeaders.host = targetBaseUrl.host;
  } catch (_) {}
  if (!upstreamHeaders['user-agent'] || String(upstreamHeaders['user-agent']).trim() === '') {
    upstreamHeaders['user-agent'] =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0 Safari/537.36';
  }
  if (!upstreamHeaders.accept) {
    upstreamHeaders.accept = 'application/json, text/plain, */*';
  }

  const upstream = upstreamClient.request(
    {
      protocol: targetBaseUrl.protocol,
      hostname: targetBaseUrl.hostname,
      port: targetBaseUrl.port || (targetBaseUrl.protocol === 'https:' ? 443 : 80),
      path: sasPath,
      method: req.method,
      headers: upstreamHeaders,
      timeout: 30000,
      agent: targetBaseUrl.protocol === 'https:' ? INSECURE_HTTPS_AGENT : undefined,
    },
    (upstreamRes) => {
      res.setHeader('X-Proxy-Target', targetBaseUrl.origin);
      res.setHeader('X-Proxy-Path', sasPath);

      const responseHeaders = filterResponseHeaders(upstreamRes.headers);
      for (const [key, value] of Object.entries(responseHeaders)) {
        try {
          res.setHeader(key, value);
        } catch (_) {
          // Ignore invalid upstream header values.
        }
      }

      applyCors(req, res);
      const diagEnabled = String(req.headers['x-sas-diag'] || '') === '1';

      if (diagEnabled) {
        const chunks = [];
        upstreamRes.on('data', (chunk) => {
          try {
            chunks.push(Buffer.from(chunk));
          } catch (_) {}
        });
        upstreamRes.on('end', () => {
          try {
            const raw = Buffer.concat(chunks || []);
            const snippet = raw.slice(0, 1024).toString('utf8');
            console.error('[SAS-DIAG] outbound-headers=', JSON.stringify(upstreamHeaders));
            console.error('[SAS-DIAG] upstream-status=', upstreamRes.statusCode);
            console.error('[SAS-DIAG] upstream-headers=', JSON.stringify(filterResponseHeaders(upstreamRes.headers)));
            console.error('[SAS-DIAG] upstream-body-snippet=', snippet.replace(/[\r\n]+/g, ' '));
          } catch (_) {}
        });
      }

      res.writeHead(upstreamRes.statusCode || 502);
      upstreamRes.pipe(res);
    }
  );

  upstream.on('timeout', () => {
    upstream.destroy(new Error('Upstream timeout'));
  });

  upstream.on('error', (error) => {
    if (!res.headersSent) {
      sendJson(req, res, 502, {error: 'SAS connection failed', message: error.message});
      return;
    }
    try {
      res.end();
    } catch (_) {
      // Ignore write errors if response is already closed.
    }
  });

  req.pipe(upstream);
}

const server = http.createServer(handleRequest);

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
