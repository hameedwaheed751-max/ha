const http = require('http');
const https = require('https');
const net = require('net');

const PORT = Number(process.env.PORT) || 3000;
const NODE_ENV = process.env.NODE_ENV || 'development';
const PROXY_TOKEN = String(process.env.PROXY_TOKEN || '').trim();
const ALLOW_INSECURE_TLS = process.env.ALLOW_INSECURE_TLS !== '0';
const ALLOW_PRIVATE_TARGETS = process.env.ALLOW_PRIVATE_TARGETS !== '0';
const REQUEST_TIMEOUT = Number(process.env.REQUEST_TIMEOUT || 45000);
const MAX_RETRIES = Number(process.env.MAX_RETRIES || 2);

// ✅ قائمة البيضاء الافتراضية تحتوي على SAS المدعومة
const DEFAULT_ALLOWLIST = [
  'sas.speednet-iq.com',
  'speednet-iq.com',
  'sas.jt.iq',
  'jt-iq.com',
  'jt.iq',
];

const TARGET_ALLOWLIST = String(process.env.SAS_TARGET_ALLOWLIST || '')
  .split(',')
  .map((item) => item.trim().toLowerCase())
  .filter(Boolean);

const EFFECTIVE_ALLOWLIST = [...new Set([...DEFAULT_ALLOWLIST, ...TARGET_ALLOWLIST])];

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
  if (!PROXY_TOKEN) return true;
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
  const host = String(hostname || '').toLowerCase();
  if (DEFAULT_ALLOWLIST.includes(host)) return true;
  if (EFFECTIVE_ALLOWLIST.length === 0) return true;
  return EFFECTIVE_ALLOWLIST.some((rule) => {
    if (rule.startsWith('*.')) {
      const suffix = rule.slice(1);
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
  if (!hostname) return 'Target host is required';
  if (isLocalHostname(hostname)) return 'Localhost targets are not allowed';
  const parsedIp = net.isIP(hostname) ? hostname : null;
  if (!ALLOW_PRIVATE_TARGETS && parsedIp && isPrivateIp(parsedIp)) {
    return 'Private IP targets are not allowed';
  }
  if (!hostAllowedByAllowlist(hostname)) {
    const allowedList = EFFECTIVE_ALLOWLIST.join(', ');
    return `Target host "${hostname}" is not in allowlist. Allowed: ${allowedList}. Set SAS_TARGET_ALLOWLIST env var to add more.`;
  }
  return null;
}

// ✅ Headers متصفح حقيقي لخداع Cloudflare و SAS
function buildUpstreamHeaders(req) {
  const headers = {};

  // Forward essential headers from client
  if (req.headers['content-type']) {
    headers['content-type'] = req.headers['content-type'];
  }
  if (req.headers['content-length']) {
    headers['content-length'] = req.headers['content-length'];
  }
  if (req.headers['authorization']) {
    headers['authorization'] = req.headers['authorization'];
  }
  if (req.headers['cookie']) {
    headers['cookie'] = req.headers['cookie'];
  }
  if (req.headers['accept']) {
    headers['accept'] = req.headers['accept'];
  }
  if (req.headers['origin']) {
    headers['origin'] = req.headers['origin'];
  }
  if (req.headers['referer']) {
    headers['referer'] = req.headers['referer'];
  }

  // Headers متصفح حقيقي - تحسين التوافق مع SAS
  headers['accept-encoding'] = 'gzip, deflate, br';
  headers['accept-language'] = 'ar-IQ,ar;q=0.9,en;q=0.8';
  headers['connection'] = 'keep-alive';
  headers['user-agent'] =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36';
  headers['sec-ch-ua'] = '"Chromium";v="138", "Google Chrome";v="138", "Not/A)Brand";v="99"';
  headers['sec-ch-ua-mobile'] = '?0';
  headers['sec-ch-ua-platform'] = '"Windows"';
  headers['sec-fetch-dest'] = 'empty';
  headers['sec-fetch-mode'] = 'cors';
  headers['sec-fetch-site'] = 'same-origin';
  headers['cache-control'] = 'no-cache';
  headers['pragma'] = 'no-cache';
  
  // Add common headers that SAS systems expect
  headers['x-requested-with'] = 'XMLHttpRequest';
  headers['x-forwarded-for'] = req.headers['x-forwarded-for'] || req.connection.remoteAddress || '';
  headers['x-forwarded-proto'] = req.headers['x-forwarded-proto'] || 'http';

  return headers;
}

function filterResponseHeaders(upstreamHeaders) {
  const hopByHop = new Set([
    'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
    'te', 'trailers', 'transfer-encoding', 'upgrade',
    'access-control-allow-origin', 'access-control-allow-credentials',
  ]);
  const out = {};
  for (const [key, value] of Object.entries(upstreamHeaders || {})) {
    if (!hopByHop.has(String(key).toLowerCase()) && value !== undefined) {
      out[key] = value;
    }
  }
  
  // Preserve cookies from upstream
  if (upstreamHeaders['set-cookie']) {
    out['set-cookie'] = upstreamHeaders['set-cookie'];
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
      allowlist: EFFECTIVE_ALLOWLIST,
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
    sendJson(req, res, 403, {error: targetError, hostname: targetBaseUrl.hostname});
    return;
  }

  const upstreamClient = targetBaseUrl.protocol === 'https:' ? https : http;
  const upstreamHeaders = buildUpstreamHeaders(req);
  
  // Session management - extract and reuse session ID
  const sessionId = getSessionId(req);
  if (sessionId) {
    console.error(`[PROXY] Using existing session: ${sessionId.substring(0, 8)}...`);
  }

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

  console.error(`[PROXY] ${req.method} ${req.url} -> ${targetBaseUrl.origin}${sasPath}`);

  // Retry logic for transient errors and 403
  let attempt = 0;
  const makeRequest = () => {
    attempt++;
    
    // Clone headers for each attempt to avoid mutation issues
    const attemptHeaders = { ...upstreamHeaders };
    
    // Add session cookie if available
    if (sessionId) {
      attemptHeaders['cookie'] = `PHPSESSID=${sessionId}; ${attemptHeaders['cookie'] || ''}`.trim();
    }
    
    const upstream = upstreamClient.request(
      {
        protocol: targetBaseUrl.protocol,
        hostname: targetBaseUrl.hostname,
        servername: targetBaseUrl.hostname,
        port: targetBaseUrl.port || (targetBaseUrl.protocol === 'https:' ? 443 : 80),
        path: sasPath,
        method: req.method,
        headers: attemptHeaders,
        timeout: REQUEST_TIMEOUT,
        agent: targetBaseUrl.protocol === 'https:' ? INSECURE_HTTPS_AGENT : undefined,
      },
      (upstreamRes) => {
        const statusCode = upstreamRes.statusCode;
        console.error(`[PROXY] Response: ${statusCode} for ${req.method} ${req.url} (attempt ${attempt})`);
        
        // Extract and store session ID from response
        const setCookieHeader = upstreamRes.headers['set-cookie'];
        if (setCookieHeader) {
          for (const cookie of setCookieHeader) {
            const match = cookie.match(/PHPSESSID=([^;]+)/);
            if (match) {
              sessionStore.set(req.connection.remoteAddress, match[1]);
              console.error(`[PROXY] Stored session: ${match[1].substring(0, 8)}...`);
            }
          }
        }
        
        res.setHeader('X-Proxy-Target', targetBaseUrl.origin);
        res.setHeader('X-Proxy-Path', sasPath);

        const responseHeaders = filterResponseHeaders(upstreamRes.headers);
        for (const [key, value] of Object.entries(responseHeaders)) {
          try {
            res.setHeader(key, value);
          } catch (_) {}
        }

        applyCors(req, res);
        const diagEnabled = String(req.headers['x-sas-diag'] || '') === '1';

        if (diagEnabled) {
          const chunks = [];
          upstreamRes.on('data', (chunk) => {
            try { chunks.push(Buffer.from(chunk)); } catch (_) {}
          });
          upstreamRes.on('end', () => {
            try {
              const raw = Buffer.concat(chunks || []);
              const text = String(raw).replace(/[\r\n]+/g, ' ');
              console.error('[SAS-DIAG] upstream-status=', statusCode);
              console.error('[SAS-DIAG] upstream-body-snippet=', text);
            } catch (err) {
              console.error('[SAS-DIAG] decompress-error=', err.message || err);
            }
          });
        }

        res.writeHead(statusCode || 502);
        upstreamRes.pipe(res);
      }
    );

    upstream.on('timeout', () => {
      console.error(`[PROXY] Timeout for ${req.method} ${req.url} (attempt ${attempt})`);
      upstream.destroy(new Error('Upstream timeout'));
    });

    upstream.on('error', (error) => {
      console.error(`[PROXY] Error for ${req.method} ${req.url} (attempt ${attempt}):`, error.message);
      
      // Retry on network errors if we haven't exceeded max retries
      if (attempt < MAX_RETRIES && (
        error.code === 'ECONNRESET' ||
        error.code === 'ECONNREFUSED' ||
        error.code === 'ETIMEDOUT' ||
        error.message.includes('timeout')
      )) {
        console.error(`[PROXY] Retrying... (attempt ${attempt + 1}/${MAX_RETRIES})`);
        setTimeout(makeRequest, 1000 * attempt);
        return;
      }
      
      if (!res.headersSent) {
        sendJson(req, res, 502, { 
          error: 'SAS connection failed', 
          message: error.message,
          target: targetBaseUrl.origin + sasPath,
          attempts: attempt
        });
        return;
      }
      try { res.end(); } catch (_) {}
    });

    return upstream;
  };

  makeRequest();

  if (String(req.headers['x-sas-diag'] || '') === '1') {
    console.error(`[SAS-DIAG] ${req.method} ${req.url}`);
    const chunks = [];
    req.on('data', (chunk) => {
      chunks.push(Buffer.from(chunk));
      upstream.write(chunk);
    });
    req.on('end', () => {
      const body = Buffer.concat(chunks).toString();
      console.error('[SAS-DIAG] request-body=', body);
      upstream.end();
    });
    return;
  }

  req.pipe(upstream);
}

// Session management for better SAS compatibility
const sessionStore = new Map();

function getSessionId(req) {
  const cookies = req.headers['cookie'] || '';
  const match = cookies.match(/PHPSESSID=([^;]+)/);
  return match ? match[1] : null;
}

function setSessionId(res, sessionId) {
  if (sessionId) {
    res.setHeader('Set-Cookie', `PHPSESSID=${sessionId}; Path=/; HttpOnly; SameSite=Lax`);
  }
}

// Error handling middleware
function logError(err, req, res, next) {
  console.error('[PROXY] Unhandled error:', err);
  if (!res.headersSent) {
    sendJson(req, res, 500, { error: 'Internal proxy error', message: err.message });
  }
}

const server = http.createServer(handleRequest);

server.on('error', (error) => {
  if (error && error.code === 'EADDRINUSE') {
    console.error(`[PROXY] Port ${PORT} is already in use. Try killing the process or use a different port.`);
    console.error(`[PROXY] Windows: netstat -ano | findstr :${PORT} && taskkill /F /PID <PID>`);
  } else {
    console.error('[PROXY] Server error:', error);
  }
  process.exit(1);
});

server.on('clientError', (err, socket) => {
  console.error('[PROXY] Client error:', err.message);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log('='.repeat(60));
  console.log('NetAgent SAS Proxy');
  console.log('='.repeat(60));
  console.log(`Port: ${PORT}`);
  console.log(`Environment: ${NODE_ENV}`);
  console.log(`Allow Insecure TLS: ${ALLOW_INSECURE_TLS}`);
  console.log(`Request Timeout: ${REQUEST_TIMEOUT}ms`);
  console.log(`Allowlist: ${EFFECTIVE_ALLOWLIST.join(', ')}`);
  console.log('='.repeat(60));
  console.log(`Proxy running at: http://localhost:${PORT}`);
  console.log(`Health check: http://localhost:${PORT}/health`);
  console.log('='.repeat(60));
});

// Graceful shutdown
process.on('SIGINT', () => {
  console.log('\n[PROXY] Shutting down gracefully...');
  server.close(() => {
    console.log('[PROXY] Server closed');
    process.exit(0);
  });
});

process.on('SIGTERM', () => {
  console.log('\n[PROXY] Received SIGTERM, shutting down...');
  server.close(() => {
    console.log('[PROXY] Server closed');
    process.exit(0);
  });
});
</arg_value></tool_call>
