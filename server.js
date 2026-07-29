const http = require('http');
const https = require('https');
const net = require('net');

const PORT = Number(process.env.PORT) || 3000;
const NODE_ENV = process.env.NODE_ENV || 'development';
const PROXY_TOKEN = String(process.env.PROXY_TOKEN || '').trim();
const DEFAULT_TARGET_URL = String(process.env.SAS_TARGET_URL || '').trim();
const ALLOW_HTTP_TARGETS = process.env.ALLOW_HTTP_TARGETS
  ? process.env.ALLOW_HTTP_TARGETS === '1'
  : NODE_ENV !== 'production';
const ALLOW_INSECURE_TLS = process.env.ALLOW_INSECURE_TLS
  ? process.env.ALLOW_INSECURE_TLS === '1'
  : NODE_ENV !== 'production';
const ALLOW_PRIVATE_TARGETS = process.env.ALLOW_PRIVATE_TARGETS
  ? process.env.ALLOW_PRIVATE_TARGETS === '1'
  : NODE_ENV !== 'production';
const TARGET_ALLOWLIST = String(process.env.SAS_TARGET_ALLOWLIST || '')
  .split(',')
  .map((item) => item.trim().toLowerCase())
  .filter(Boolean);

if (ALLOW_INSECURE_TLS) {
  // Use only when SAS uses self-signed or invalid certificates.
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
  console.warn('WARNING: TLS certificate verification is disabled (ALLOW_INSECURE_TLS=1).');
}

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

  if (targetBaseUrl.protocol !== 'https:' && NODE_ENV === 'production' && !ALLOW_HTTP_TARGETS) {
    return 'Only https SAS targets are allowed in production';
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

function normalizeSasPath(reqUrl) {
  let parsed;
  try {
    parsed = new URL(reqUrl || '/', 'http://netagent.local');
  } catch (_) {
    return null;
  }

  let path;
  if (parsed.pathname === '/login') {
    path = '/admin/api/index.php/api/login';
  } else if (parsed.pathname === '/sas') {
    path = '/';
  } else if (parsed.pathname.startsWith('/sas/')) {
    path = parsed.pathname.substring(4);
  } else if (
    parsed.pathname.startsWith('/admin/api/') ||
    parsed.pathname.startsWith('/api/') ||
    parsed.pathname.startsWith('/index.php/')
  ) {
    path = parsed.pathname;
  } else {
    return null;
  }

  if (!path.startsWith('/')) {
    path = `/${path}`;
  }

  // Guard against client-side base URL mistakes that create duplicated SAS API
  // segments such as /api/index.php/api/api/index.php/api/login.
  path = path
    .replace(/\/admin\/api\/index\.php\/api\/admin\/api\/index\.php\/api/ig, '/admin/api/index.php/api')
    .replace(/\/api\/index\.php\/api\/api\/index\.php\/api/ig, '/api/index.php/api')
    .replace(/\/api\/api\//ig, '/api/');

  return `${path}${parsed.search || ''}`;
}

function resolveTargetOrigin(req, parsedRequestUrl) {
  const headerTarget = String(req.headers['x-sas-target'] || '').trim();
  if (headerTarget) return headerTarget;

  const queryTarget = String(parsedRequestUrl.searchParams.get('target') || '').trim();
  if (queryTarget) return queryTarget;

  if (DEFAULT_TARGET_URL) return DEFAULT_TARGET_URL;
  return '';
}

function splitPathAndSearch(rawPath) {
  const idx = rawPath.indexOf('?');
  if (idx < 0) return {pathOnly: rawPath, search: ''};
  return {pathOnly: rawPath.slice(0, idx), search: rawPath.slice(idx)};
}

function buildUpstreamPath(targetBaseUrl, sasPath) {
  const {pathOnly, search} = splitPathAndSearch(sasPath);
  const targetPrefix = String(targetBaseUrl.pathname || '/').replace(/\/+$/, '');

  if (!targetPrefix || targetPrefix === '/') {
    return `${pathOnly}${search}`;
  }

  const reqLower = pathOnly.toLowerCase();
  const prefixLower = targetPrefix.toLowerCase();

  // If request already starts with target prefix, do not prepend again.
  if (reqLower === prefixLower || reqLower.startsWith(`${prefixLower}/`)) {
    return `${pathOnly}${search}`;
  }

  const apiBases = ['/admin/api/index.php/api', '/api/index.php/api'];
  const sharedApiBase = apiBases.find((base) =>
    prefixLower.endsWith(base) && (reqLower === base || reqLower.startsWith(`${base}/`))
  );

  if (sharedApiBase) {
    const suffix = pathOnly.slice(sharedApiBase.length);
    return `${targetPrefix}${suffix}${search}`;
  }

  const joined = `${targetPrefix}/${pathOnly.replace(/^\/+/, '')}`.replace(/\/+/g, '/');
  return `${joined}${search}`;
}

function buildUpstreamHeaders(req) {
  const allowedRequestHeaders = [
    'accept',
    'accept-language',
    'authorization',
    'content-type',
    'allow-cache-y',
    'user-agent',
  ];

  const headers = {};
  for (const key of allowedRequestHeaders) {
    if (req.headers[key] !== undefined) {
      headers[key] = req.headers[key];
    }
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
    const raw = Buffer.concat(chunks).toString('utf8');
    sendJson(req, res, upstreamRes.statusCode || 502, {
      error: 'SAS upstream returned HTML error',
      status: upstreamRes.statusCode || 502,
      target: targetBaseUrl.origin,
      path: sasPath,
      body: raw.substring(0, 400),
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

  let parsedHealthUrl;
  try {
    parsedHealthUrl = new URL(req.url || '/', 'https://netagent.local');
  } catch (_) {
    parsedHealthUrl = new URL('/', 'https://netagent.local');
  }

  if (parsedHealthUrl.pathname === '/' || parsedHealthUrl.pathname === '/health' || parsedHealthUrl.pathname === '/healthz') {
    sendJson(req, res, 200, {
      ok: true,
      service: 'NetAgent SAS Proxy',
      env: NODE_ENV,
      port: PORT,
      hasDefaultTarget: Boolean(DEFAULT_TARGET_URL),
      allowHttpTargets: ALLOW_HTTP_TARGETS,
      allowInsecureTls: ALLOW_INSECURE_TLS,
      allowPrivateTargets: ALLOW_PRIVATE_TARGETS,
      hasTokenAuth: Boolean(PROXY_TOKEN),
      hasAllowlist: TARGET_ALLOWLIST.length > 0,
      routes: ['/health', '/healthz', '/sas/*', '/login', '/admin/api/*', '/api/*', '/index.php/*'],
    });
    return;
  }

  if (!hasValidProxyToken(req)) {
    sendJson(req, res, 401, {error: 'Unauthorized'});
    return;
  }

  const sasPath = normalizeSasPath(req.url);
  if (!sasPath) {
    sendJson(req, res, 404, {error: 'Not Found'});
    return;
  }

  let parsedRequestUrl;
  try {
    parsedRequestUrl = new URL(req.url || '/', 'https://netagent.local');
  } catch (_) {
    parsedRequestUrl = new URL('/', 'https://netagent.local');
  }

  const targetOriginRaw = resolveTargetOrigin(req, parsedRequestUrl);
  if (!targetOriginRaw) {
    sendJson(req, res, 400, {
      error: 'Missing SAS target',
      hint: 'Provide X-SAS-Target header, ?target=https://sas-host, or SAS_TARGET_URL env var',
    });
    return;
  }

  const targetOrigin = targetOriginRaw.replace(/\/+$/, '');
  let targetBaseUrl;
  try {
    targetBaseUrl = new URL(targetOrigin);
  } catch (_) {
    sendJson(req, res, 400, {
      error: 'Invalid SAS target URL',
      hint: 'Use a full URL like https://sas.example.com or https://sas.example.com/admin/api/index.php/api',
    });
    return;
  }

  const targetError = validateTarget(targetBaseUrl);
  if (targetError) {
    sendJson(req, res, 403, {error: targetError});
    return;
  }

  const upstreamClient = targetBaseUrl.protocol === 'https:' ? https : http;
  const upstreamHeaders = buildUpstreamHeaders(req);
  const upstreamPath = buildUpstreamPath(targetBaseUrl, sasPath);

  const upstream = upstreamClient.request(
    {
      protocol: targetBaseUrl.protocol,
      hostname: targetBaseUrl.hostname,
      port: targetBaseUrl.port || (targetBaseUrl.protocol === 'https:' ? 443 : 80),
      path: upstreamPath,
      method: req.method,
      headers: upstreamHeaders,
      timeout: 30000,
    },
    (upstreamRes) => {
      res.setHeader('X-Proxy-Target', targetBaseUrl.origin);
      res.setHeader('X-Proxy-Path', upstreamPath);

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
