const http = require('http');
const https = require('https');
const net = require('net');
const zlib = require('zlib');

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
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
  console.warn('WARNING: TLS certificate verification is disabled (ALLOW_INSECURE_TLS=1).');
}

const INSECURE_HTTPS_AGENT = new https.Agent({
  rejectUnauthorized: !ALLOW_INSECURE_TLS,
});

if (TARGET_ALLOWLIST.length === 0) {
  console.warn('WARNING: SAS_TARGET_ALLOWLIST is empty. Any public target host is allowed.');
}

function applyCors(req, res) {
  const requestedHeaders = req.headers['access-control-request-headers'];
  const allowOrigin = process.env.CORS_ALLOW_ORIGIN || '*';
  res.setHeader('Access-Control-Allow-Origin', allowOrigin);
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,PATCH,DELETE,OPTIONS');
  res.setHeader(
    'Access-Control-Allow-Headers',
    requestedHeaders || 'Content-Type, Authorization, Allow-Cache-Y, X-SAS-Target, X-Proxy-Token'
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
  // Compatibility mode: forward most incoming headers.
  const headers = {...req.headers};
  delete headers.host;
  delete headers.origin;
  delete headers.referer;
  delete headers['x-sas-target'];
  delete headers['x-proxy-token'];

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

function redactSensitiveText(value) {
  const text = String(value ?? '');
  return text
    .replace(/(authorization\s*[:=]\s*)([^,\s;]+)/gi, '$1[REDACTED]')
    .replace(/(cookie\s*[:=]\s*)([^,\s;]+)/gi, '$1[REDACTED]')
    .replace(/(set-cookie\s*[:=]\s*)([^,\s;]+)/gi, '$1[REDACTED]')
    .replace(/(x-proxy-token\s*[:=]\s*)([^,\s;]+)/gi, '$1[REDACTED]')
    .replace(/(token\s*[:=]\s*)([^,\s;]+)/gi, '$1[REDACTED]')
    .replace(/(password\s*[:=]\s*)([^,\s;]+)/gi, '$1[REDACTED]')
    .replace(/(username\s*[:=]\s*)([^,\s;]+)/gi, '$1[REDACTED]')
    .replace(/\b(bearer)\s+([a-z0-9\-_\.]+)/gi, '$1 [REDACTED]');
}

function normalizeContentEncoding(value) {
  if (!value) return '';
  return String(value)
    .split(',')[0]
    .trim()
    .toLowerCase();
}

function decompressResponseBody(buffer, contentEncoding) {
  const encoding = normalizeContentEncoding(contentEncoding);
  try {
    if (encoding === 'gzip') {
      return zlib.gunzipSync(buffer);
    }
    if (encoding === 'deflate') {
      return zlib.inflateSync(buffer);
    }
    if (encoding === 'br' && typeof zlib.brotliDecompressSync === 'function') {
      return zlib.brotliDecompressSync(buffer);
    }
  } catch (_) {
    // ignore decompression failure and fall back to raw bytes
  }
  return buffer;
}

function maybeDecodeResponseBody(buffer, contentEncoding) {
  if (!Buffer.isBuffer(buffer)) {
    buffer = Buffer.from(String(buffer ?? ''), 'utf8');
  }
  const decoded = decompressResponseBody(buffer, contentEncoding);
  return decoded.toString('utf8');
}

function sanitizeResponseHeaders(headers) {
  const sensitiveKeys = new Set([
    'authorization',
    'proxy-authorization',
    'cookie',
    'set-cookie',
    'x-proxy-token',
    'x-api-key',
    'api-key',
    'token',
    'access-token',
    'refresh-token',
  ]);

  const out = {};
  for (const [key, value] of Object.entries(headers || {})) {
    const lower = String(key).toLowerCase();
    if (sensitiveKeys.has(lower)) {
      out[key] = '[REDACTED]';
    } else if (value !== undefined) {
      out[key] = value;
    }
  }
  return out;
}

function logSasResponse(targetBaseUrl, sasPath, statusCode, headers, contentEncoding, body) {
  const targetUrl = `${targetBaseUrl.origin}${sasPath}`;
  const safeHeaders = sanitizeResponseHeaders(headers);
  const safeBody = redactSensitiveText(String(body ?? ''));
  const snippet = safeBody.substring(0, 2000);

  console.warn(`[SAS-DEBUG] target=${targetUrl}`);
  console.warn(`[SAS-DEBUG] path=${sasPath}`);
  console.warn(`[SAS-DEBUG] status=${statusCode}`);
  console.warn(`[SAS-DEBUG] content-encoding=${contentEncoding || 'identity'}`);
  console.warn(`[SAS-DEBUG] headers=${JSON.stringify(safeHeaders)}`);
  console.warn(`[SAS-DEBUG] body=${snippet}`);
}

function handleHtmlError(req, res, upstreamRes, targetBaseUrl, sasPath) {
  const MAX_CAPTURE_BYTES = 256 * 1024;
  const chunks = [];
  let total = 0;

  upstreamRes.on('data', (chunk) => {
    total += chunk.length;
    if (total <= MAX_CAPTURE_BYTES) {
      chunks.push(chunk);
    }
  });

  upstreamRes.on('end', () => {
    const rawBuffer = Buffer.concat(chunks);
    const contentEncoding = String(upstreamRes.headers['content-encoding'] || '').toLowerCase();
    const decoded = maybeDecodeResponseBody(rawBuffer, contentEncoding);
    logSasResponse(targetBaseUrl, sasPath, upstreamRes.statusCode || 502, upstreamRes.headers || {}, contentEncoding, decoded);
    sendJson(req, res, upstreamRes.statusCode || 502, {
      error: 'SAS upstream returned HTML error',
      status: upstreamRes.statusCode || 502,
      target: targetBaseUrl.origin,
      path: sasPath,
      body: decoded.substring(0, 400),
      truncated: total > MAX_CAPTURE_BYTES,
    });
  });
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

  const sasPath = req.url.substring(4);
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

      const contentType = String(responseHeaders['content-type'] || '').toLowerCase();
      if ((upstreamRes.statusCode || 0) >= 400 && contentType.includes('text/html')) {
        handleHtmlError(req, res, upstreamRes, targetBaseUrl, sasPath);
        return;
      }

      const chunks = [];
      upstreamRes.on('data', (chunk) => {
        chunks.push(chunk);
      });
      upstreamRes.on('end', () => {
        const rawBuffer = Buffer.concat(chunks);
        const contentEncoding = String(upstreamRes.headers['content-encoding'] || '').toLowerCase();
        const decoded = maybeDecodeResponseBody(rawBuffer, contentEncoding);
        logSasResponse(targetBaseUrl, sasPath, upstreamRes.statusCode || 502, upstreamRes.headers || {}, contentEncoding, decoded);
      });

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
