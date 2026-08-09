const http = require('http');
const https = require('https');
const net = require('net');

const PORT = Number(process.env.PORT) || 3000;
const NODE_ENV = process.env.NODE_ENV || 'development';
const PROXY_TOKEN = String(process.env.PROXY_TOKEN || '').trim();
const SAS_PROXY_TOKEN = String(process.env.SAS_PROXY_TOKEN || '').trim();
const WHATSAPP_ACCESS_TOKEN = String(process.env.WHATSAPP_ACCESS_TOKEN || '').trim();
const WHATSAPP_TOKEN = String(process.env.WHATSAPP_TOKEN || '').trim();
const PHONE_NUMBER_ID = String(process.env.PHONE_NUMBER_ID || '').trim();
const WHATSAPP_PHONE_NUMBER_ID = String(process.env.WHATSAPP_PHONE_NUMBER_ID || '').trim();
const WHATSAPP_VERIFY_TOKEN = String(process.env.WHATSAPP_VERIFY_TOKEN || '').trim();
const WHATSAPP_API_VERSION = String(process.env.WHATSAPP_API_VERSION || 'v22.0').trim();
const WHATSAPP_BUSINESS_ACCOUNT_ID = String(
  process.env.WHATSAPP_BUSINESS_ACCOUNT_ID ||
    process.env.WABA_ID ||
    '2247793002705802'
).trim();
const RENDER_GIT_COMMIT = String(process.env.RENDER_GIT_COMMIT || '').trim();
let discoveredWhatsAppBusinessAccountId = WHATSAPP_BUSINESS_ACCOUNT_ID;
const DEFAULT_TARGET_URL = String(process.env.SAS_TARGET_URL || '').trim();
const MAX_BODY_BYTES = Number(process.env.MAX_BODY_BYTES || 5 * 1024 * 1024);
const DISABLE_PROXY_AUTH = process.env.DISABLE_PROXY_AUTH === '1' || process.env.ALLOW_UNAUTHENTICATED_PROXY === '1';
const CONFIGURED_PROXY_TOKENS = Array.from(
  new Set(
    [PROXY_TOKEN, SAS_PROXY_TOKEN, String(process.env.SAS_PROXY_TOKENS || '').trim()]
      .flatMap((value) => String(value || '').split(','))
      .map((item) => item.trim())
      .filter(Boolean)
  )
);
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

if (NODE_ENV === 'production' && !DISABLE_PROXY_AUTH && CONFIGURED_PROXY_TOKENS.length === 0) {
  console.warn('WARNING: Proxy auth is enabled but no proxy token is configured. Set PROXY_TOKEN or SAS_PROXY_TOKEN.');
}

function applyCors(req, res) {
  const requestedHeaders = req.headers['access-control-request-headers'];
  const allowOrigin = process.env.CORS_ALLOW_ORIGIN || '*';
  res.setHeader('Access-Control-Allow-Origin', allowOrigin);
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,PATCH,DELETE,OPTIONS');
  res.setHeader(
    'Access-Control-Allow-Headers',
    requestedHeaders || 'Content-Type, Authorization, Allow-Cache-Y, X-SAS-Target, X-Proxy-Token, X-WA-Phone, X-WA-Message-B64'
  );
  res.setHeader('Access-Control-Max-Age', '86400');
}

function sendJson(req, res, status, payload) {
  applyCors(req, res);
  res.writeHead(status, {'Content-Type': 'application/json; charset=utf-8'});
  res.end(JSON.stringify(payload));
}

function hasValidProxyToken(req) {
  if (CONFIGURED_PROXY_TOKENS.length === 0) {
    return true;
  }

  const xToken = String(req.headers['x-proxy-token'] || '').trim();
  const altToken = String(req.headers['x-sas-proxy-token'] || '').trim();
  const apiKey = String(req.headers['x-api-key'] || '').trim();
  const auth = String(req.headers.authorization || '').trim();
  const bearer = auth.toLowerCase().startsWith('bearer ') ? auth.slice(7).trim() : '';

  return [xToken, altToken, apiKey, bearer].some((candidate) =>
    candidate && CONFIGURED_PROXY_TOKENS.includes(candidate)
  );
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

  const pathname = String(parsed.pathname || '/');
  let path;
  if (pathname === '/login' || pathname === '/sas/login') {
    path = '/admin/api/index.php/api/login';
  } else if (pathname === '/sas' || pathname === '/') {
    path = '/';
  } else if (pathname.startsWith('/sas/')) {
    path = pathname.substring(4);
  } else if (
    pathname.startsWith('/admin/api/') ||
    pathname.startsWith('/api/') ||
    pathname.startsWith('/index.php/')
  ) {
    path = pathname;
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

  // Remove proxy control params before forwarding to SAS.
  parsed.searchParams.delete('target');
  const cleanedSearch = parsed.searchParams.toString();
  return `${path}${cleanedSearch ? `?${cleanedSearch}` : ''}`;
}

function resolveTargetOrigin(req, parsedRequestUrl) {
  const headerTarget = String(req.headers['x-sas-target'] || '').trim();
  if (headerTarget) return normalizeTargetValue(headerTarget);

  const queryTarget = String(parsedRequestUrl.searchParams.get('target') || '').trim();
  if (queryTarget) return normalizeTargetValue(queryTarget);

  if (DEFAULT_TARGET_URL) return normalizeTargetValue(DEFAULT_TARGET_URL);
  return '';
}

function splitPathAndSearch(rawPath) {
  const idx = rawPath.indexOf('?');
  if (idx < 0) return {pathOnly: rawPath, search: ''};
  return {pathOnly: rawPath.slice(0, idx), search: rawPath.slice(idx)};
}

function normalizeTargetValue(rawValue) {
  const value = String(rawValue || '').trim();
  if (!value) return '';

  const candidate = /^https?:\/\//i.test(value) ? value : `https://${value}`;
  let parsed;
  try {
    parsed = new URL(candidate);
  } catch (_) {
    return '';
  }

  const origin = `${parsed.protocol}//${parsed.host}`;
  const pathname = parsed.pathname && parsed.pathname !== '/' ? parsed.pathname.replace(/\/+$/, '') : '';
  const search = parsed.search || '';
  return `${origin}${pathname}${search}`;
}

function buildUpstreamPath(targetBaseUrl, sasPath) {
  const {pathOnly, search} = splitPathAndSearch(sasPath);
  const targetPrefix = String(targetBaseUrl.pathname || '/').replace(/\/+$/, '');
  const normalizedPath = pathOnly.startsWith('/') ? pathOnly : `/${pathOnly}`;

  if (!targetPrefix || targetPrefix === '/') {
    return `${normalizedPath}${search}`;
  }

  const reqLower = normalizedPath.toLowerCase();
  const prefixLower = targetPrefix.toLowerCase();

  // If request already starts with target prefix, do not prepend again.
  if (reqLower === prefixLower || reqLower.startsWith(`${prefixLower}/`)) {
    return `${pathOnly}${search}`;
  }

  const apiBases = ['/admin/api/index.php/api', '/api/index.php/api', '/index.php/api'];
  const sharedApiBase = apiBases.find((base) =>
    prefixLower.endsWith(base) && (reqLower === base || reqLower.startsWith(`${base}/`))
  );

  if (sharedApiBase) {
    const suffix = normalizedPath.slice(sharedApiBase.length);
    return `${targetPrefix}${suffix}${search}`;
  }

  const joined = `${targetPrefix}/${normalizedPath.replace(/^\/+/, '')}`.replace(/\/+/, '/');
  return `${joined}${search}`;
}

function buildPathCandidates(primaryPath) {
  const variants = ['/admin/api/index.php/api', '/api/index.php/api', '/index.php/api'];
  const {pathOnly, search} = splitPathAndSearch(primaryPath);
  const unique = [];
  const seen = new Set();

  const add = (value) => {
    const k = String(value || '').trim();
    if (!k || seen.has(k)) return;
    seen.add(k);
    unique.push(k);
  };

  add(`${pathOnly}${search}`);

  for (const fromBase of variants) {
    if (!pathOnly.startsWith(fromBase)) continue;
    const suffix = pathOnly.slice(fromBase.length);
    for (const toBase of variants) {
      if (toBase === fromBase) continue;
      add(`${toBase}${suffix}${search}`);
    }
  }

  return unique;
}

function buildUpstreamHeaders(req) {
  const allowedRequestHeaders = [
    'accept',
    'accept-language',
    'authorization',
    'content-type',
    'content-length',
    'allow-cache-y',
    'user-agent',
    'x-requested-with',
  ];

  const headers = {};
  for (const key of allowedRequestHeaders) {
    if (req.headers[key] !== undefined) {
      headers[key] = req.headers[key];
    }
  }

  if (!headers['user-agent']) {
    headers['user-agent'] =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      + '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  }

  if (!headers.accept) {
    headers.accept = 'application/json, text/plain, */*';
  }

  if (!headers['accept-language']) {
    headers['accept-language'] = 'en-US,en;q=0.9';
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

function decodeBase64Utf8(value) {
  try {
    if (!value) return '';
    return Buffer.from(String(value), 'base64').toString('utf8').trim();
  } catch (_) {
    return '';
  }
}

function readJsonBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;

    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > maxBytes) {
        reject({statusCode: 413, message: 'Payload too large'});
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on('error', (error) => {
      reject({statusCode: 400, message: `Failed to read request body: ${error.message}`});
    });

    req.on('end', () => {
      const raw = chunks.length > 0 ? Buffer.concat(chunks).toString('utf8') : '';
      if (!raw.trim()) {
        resolve({});
        return;
      }

      try {
        resolve(JSON.parse(raw));
      } catch (_) {
        reject({statusCode: 400, message: 'Invalid JSON body'});
      }
    });
  });
}

function readRawBody(req, maxBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;

    req.on('data', (chunk) => {
      total += chunk.length;
      if (total > maxBytes) {
        reject({statusCode: 413, message: 'Payload too large'});
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on('error', (error) => {
      reject({statusCode: 400, message: `Failed to read request body: ${error.message}`});
    });

    req.on('end', () => {
      resolve(chunks.length > 0 ? Buffer.concat(chunks).toString('utf8') : '');
    });
  });
}

function isActivationPath(pathname) {
  const p = String(pathname || '').toLowerCase();
  return p.includes('/user/activate');
}

function activationSucceeded(statusCode, responseText) {
  if (!(statusCode >= 200 && statusCode < 300)) {
    return false;
  }

  try {
    const parsed = JSON.parse(responseText || '{}');
    if (!parsed || typeof parsed !== 'object') return true;

    const status = parsed.status;
    const success = parsed.success;
    const msg = String(parsed.message || parsed.msg || parsed.error || '').toLowerCase();

    if (success === false || status === false) return false;
    if (status === -1 || status === '-1' || status === 0 || status === '0') return false;
    if (typeof status === 'number' && status >= 400) return false;
    if (msg.includes('error') || msg.includes('fail')) return false;
    return true;
  } catch (_) {
    // Non-JSON success response from upstream should still be considered success by HTTP status.
    return true;
  }
}

async function sendWhatsApp(phone, message) {
  const cleanPhone = String(phone || '').replace(/\D/g, '').trim();
  const body = String(message || '').trim();

  if (!cleanPhone || !body) {
    return {ok: false, skipped: true, reason: 'Missing phone or message'};
  }

  if (!(WHATSAPP_ACCESS_TOKEN || WHATSAPP_TOKEN) || !(WHATSAPP_PHONE_NUMBER_ID || PHONE_NUMBER_ID)) {
    return {ok: false, skipped: true, reason: 'Missing WHATSAPP_TOKEN or PHONE_NUMBER_ID'};
  }

  await sendWhatsAppText(cleanPhone, body);
  return {ok: true};
}

async function sendWhatsAppText(to, message) {
  const accessToken = WHATSAPP_ACCESS_TOKEN || WHATSAPP_TOKEN;
  const phoneNumberId = WHATSAPP_PHONE_NUMBER_ID || PHONE_NUMBER_ID;
  const cleanTo = String(to || '').replace(/\D/g, '').trim();
  const body = String(message || '').trim();

  if (!phoneNumberId || !accessToken) {
    const err = new Error('Missing WHATSAPP_TOKEN or PHONE_NUMBER_ID');
    err.statusCode = 500;
    throw err;
  }

  if (!cleanTo || !body) {
    const err = new Error('Both "to" and "message" are required');
    err.statusCode = 400;
    throw err;
  }

  const endpoint = `https://graph.facebook.com/v23.0/${phoneNumberId}/messages`;
  console.log('[whatsapp] outbound text payload:', JSON.stringify({
    to: cleanTo,
    type: 'text',
    textLength: body.length,
  }));
  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      messaging_product: 'whatsapp',
      to: cleanTo,
      type: 'text',
      text: {
        body,
      },
    }),
  });

  const raw = await response.text();
  console.log(`[whatsapp] text response status=${response.status} body=${raw || '<empty>'}`);
  let parsed;
  try {
    parsed = raw ? JSON.parse(raw) : {};
  } catch (_) {
    parsed = {raw};
  }

  if (!response.ok) {
    const metaCode = Number(parsed?.error?.code) || 0;
    const err = new Error(
      metaCode === 131047
        ? 'Free-form WhatsApp text is blocked outside the 24-hour customer service window; use an approved template'
        : 'WhatsApp API request failed'
    );
    err.statusCode = response.status;
    err.details = parsed;
    throw err;
  }

  return parsed;
}

const templateContractCache = new Map();
const TEMPLATE_CONTRACT_TTL_MS = 5 * 60 * 1000;

async function fetchMetaJson(path, accessToken) {
  const endpoint = `https://graph.facebook.com/${WHATSAPP_API_VERSION}/${path}`;
  const response = await fetch(endpoint, {
    headers: {Authorization: `Bearer ${accessToken}`},
  });
  const raw = await response.text();
  let parsed;
  try {
    parsed = raw ? JSON.parse(raw) : {};
  } catch (_) {
    parsed = {raw};
  }

  if (!response.ok) {
    const err = new Error('Failed to read WhatsApp template definition from Meta');
    err.statusCode = response.status;
    err.details = parsed;
    throw err;
  }
  return parsed;
}

async function resolveWhatsAppBusinessAccountId(phoneNumberId, accessToken) {
  if (discoveredWhatsAppBusinessAccountId) {
    return discoveredWhatsAppBusinessAccountId;
  }

  const phone = await fetchMetaJson(
    `${encodeURIComponent(phoneNumberId)}?fields=whatsapp_business_account`,
    accessToken
  );
  const accountId = String(phone?.whatsapp_business_account?.id || '').trim();
  if (!accountId) {
    const err = new Error(
      'Set WHATSAPP_BUSINESS_ACCOUNT_ID on Render so approved template variables can be verified'
    );
    err.statusCode = 500;
    throw err;
  }
  discoveredWhatsAppBusinessAccountId = accountId;
  return accountId;
}

async function getApprovedTemplateContract(templateName, languageCode, phoneNumberId, accessToken) {
  const cacheKey = `${templateName}:${languageCode}`;
  const cached = templateContractCache.get(cacheKey);
  if (cached && Date.now() - cached.at < TEMPLATE_CONTRACT_TTL_MS) {
    return cached.contract;
  }

  const accountId = await resolveWhatsAppBusinessAccountId(phoneNumberId, accessToken);
  const query = new URLSearchParams({
    name: templateName,
    fields: 'name,language,status,parameter_format,components',
    limit: '100',
  });
  const response = await fetchMetaJson(
    `${encodeURIComponent(accountId)}/message_templates?${query.toString()}`,
    accessToken
  );
  const template = (Array.isArray(response?.data) ? response.data : []).find(
    (item) => String(item?.name || '') === templateName &&
      String(item?.language || '').toLowerCase() === languageCode.toLowerCase() &&
      String(item?.status || '').toUpperCase() === 'APPROVED'
  );
  if (!template) {
    const err = new Error(`Approved Meta template ${templateName}/${languageCode} was not found`);
    err.statusCode = 400;
    err.details = {templateName, languageCode};
    throw err;
  }

  const body = (Array.isArray(template.components) ? template.components : []).find(
    (component) => String(component?.type || '').toUpperCase() === 'BODY'
  );
  const bodyText = String(body?.text || '');
  const names = Array.from(
    bodyText.matchAll(/\{\{\s*([^{}]+?)\s*\}\}/g),
    (match) => match[1].trim()
  );
  const uniqueNames = Array.from(new Set(names));
  const parameterFormat = String(template.parameter_format || '').toUpperCase();
  if (parameterFormat && parameterFormat !== 'NAMED') {
    const err = new Error(`Meta template ${templateName} must use NAMED parameters`);
    err.statusCode = 400;
    err.details = {templateName, parameterFormat};
    throw err;
  }
  if (uniqueNames.length === 0) {
    const err = new Error(`Meta template ${templateName} has no recognized named BODY variables`);
    err.statusCode = 400;
    err.details = {templateName, bodyText};
    throw err;
  }

  const contract = {names: uniqueNames, bodyText};
  templateContractCache.set(cacheKey, {at: Date.now(), contract});
  console.log('[whatsapp] approved template contract:', JSON.stringify({
    templateName,
    languageCode,
    parameterNames: uniqueNames,
  }));
  return contract;
}

async function sendWhatsAppTemplate(
  to,
  templateName,
  languageCode = 'ar',
  parameters = [],
  templateVariables = {}
) {
  const accessToken = WHATSAPP_ACCESS_TOKEN || WHATSAPP_TOKEN;
  const phoneNumberId = WHATSAPP_PHONE_NUMBER_ID || PHONE_NUMBER_ID;
  const cleanTo = String(to || '').replace(/\D/g, '').trim();
  const name = String(templateName || '').trim();
  const lang = String(languageCode || 'ar').trim() || 'ar';
  const suppliedParameters = Array.isArray(parameters)
    ? parameters.map((parameter, index) => {
        const text = parameter && typeof parameter === 'object'
          ? String(parameter.text || parameter.value || '').trim()
          : '';
        const parameterName = parameter && typeof parameter === 'object'
          ? String(
              parameter.parameterName || parameter.parameter_name || parameter.name || ''
            ).trim()
          : '';

        if (!parameterName || !text) {
          const err = new Error(
            `Template parameter ${index + 1} requires non-empty parameter_name and text`
          );
          err.statusCode = 400;
          err.details = {templateName: name, parameterIndex: index};
          throw err;
        }

        return {
          type: 'text',
          parameter_name: parameterName,
          text,
        };
      })
    : [];

  if (!phoneNumberId || !accessToken) {
    const err = new Error('Missing WHATSAPP_TOKEN or PHONE_NUMBER_ID');
    err.statusCode = 500;
    throw err;
  }

  if (!cleanTo || !name) {
    const err = new Error('Both "to" and "templateName" are required');
    err.statusCode = 400;
    throw err;
  }

  const canonicalValues = templateVariables && typeof templateVariables === 'object'
    ? Object.fromEntries(
        Object.entries(templateVariables).map(([key, value]) => [key, String(value || '').trim()])
      )
    : {};
  const contract = await getApprovedTemplateContract(name, lang, phoneNumberId, accessToken);
  const metaVariableAliases = {
    'اسم المشترك': 'customer_name',
    'مبلغ الدين': 'debt_amount',
    'التاريخ': 'notification_date',
    'اسم الوكيل': 'agent_name',
  };
  const bodyParameters = contract.names.map((parameterName) => {
    const canonicalName = metaVariableAliases[parameterName] || parameterName;
    const text = canonicalValues[canonicalName] ||
      suppliedParameters.find((parameter) => parameter.parameter_name === parameterName)?.text ||
      '';
    if (!text) {
      const err = new Error(
        `No application value is available for Meta variable ${parameterName} in ${name}`
      );
      err.statusCode = 400;
      err.details = {templateName: name, parameterName, expectedParameters: contract.names};
      throw err;
    }
    return {type: 'text', parameter_name: parameterName, text};
  });

  const endpoint = `https://graph.facebook.com/v23.0/${phoneNumberId}/messages`;
  const payload = {
    messaging_product: 'whatsapp',
    to: cleanTo,
    type: 'template',
    template: {
      name,
      language: {code: lang},
      ...(bodyParameters.length > 0
        ? {
            components: [
              {
                type: 'body',
                parameters: bodyParameters,
              },
            ],
          }
        : {}),
    },
  };

  console.log('[whatsapp] outbound template payload:', JSON.stringify(payload));

  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${accessToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(payload),
  });

  const raw = await response.text();
  console.log(`[whatsapp] template response status=${response.status} body=${raw || '<empty>'}`);
  let parsed;
  try {
    parsed = raw ? JSON.parse(raw) : {};
  } catch (_) {
    parsed = {raw};
  }

  if (!response.ok) {
    const err = new Error('WhatsApp API request failed');
    err.statusCode = response.status;
    err.details = parsed;
    throw err;
  }

  return parsed;
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
      hasTokenAuth: CONFIGURED_PROXY_TOKENS.length > 0,
      proxyAuthBypassed: DISABLE_PROXY_AUTH,
      hasAllowlist: TARGET_ALLOWLIST.length > 0,
      routes: ['/health', '/healthz', '/ping-target', '/whatsapp/send', '/sas/*', '/login', '/admin/api/*', '/api/*', '/index.php/*'],
      commit: RENDER_GIT_COMMIT || null,
      hasWhatsAppBusinessAccountId: Boolean(WHATSAPP_BUSINESS_ACCOUNT_ID),
      hasDiscoveredWhatsAppBusinessAccountId: Boolean(discoveredWhatsAppBusinessAccountId),
    });
    return;
  }

  if (parsedHealthUrl.pathname === '/webhook') {
    if (req.method === 'GET') {
      const mode = String(parsedHealthUrl.searchParams.get('hub.mode') || '').trim();
      const verifyToken = String(parsedHealthUrl.searchParams.get('hub.verify_token') || '').trim();
      const challenge = String(parsedHealthUrl.searchParams.get('hub.challenge') || '').trim();

      console.log(
        `[webhook] verify request mode=${mode || '-'} tokenPresent=${verifyToken ? 'yes' : 'no'} challengePresent=${challenge ? 'yes' : 'no'}`
      );

      if (mode === 'subscribe' && WHATSAPP_VERIFY_TOKEN && verifyToken === WHATSAPP_VERIFY_TOKEN && challenge) {
        res.writeHead(200, {'Content-Type': 'text/plain; charset=utf-8'});
        res.end(challenge);
        console.log('[webhook] verify success');
        return;
      }

      console.log('[webhook] verify failed');
      sendJson(req, res, 403, {error: 'Forbidden'});
      return;
    }

    if (req.method === 'POST') {
      console.log('[webhook] event received');
      res.writeHead(200, {'Content-Type': 'text/plain; charset=utf-8'});
      res.end('OK');

      (async () => {
        try {
          const rawBody = await readRawBody(req, MAX_BODY_BYTES);
          try {
            const parsed = rawBody ? JSON.parse(rawBody) : {};
            const webhookAccountId = String(parsed?.entry?.[0]?.id || '').trim();
            if (webhookAccountId) {
              discoveredWhatsAppBusinessAccountId = webhookAccountId;
            }
            console.log('[webhook] WhatsApp event body JSON:', JSON.stringify(parsed));
          } catch (_) {
            console.log('[webhook] WhatsApp event body RAW:', rawBody);
          }
        } catch (error) {
          console.error('[webhook] Failed to read body:', error && error.message ? error.message : error);
        }
      })();

      return;
    }

    sendJson(req, res, 405, {error: 'Method Not Allowed'});
    return;
  }

  // تشخيص: اختبار الوصول لسيرفر SAS بدون إرسال بيانات
  if (parsedHealthUrl.pathname === '/ping-target') {
    const pingTarget = String(
      parsedHealthUrl.searchParams.get('target') ||
      req.headers['x-sas-target'] ||
      DEFAULT_TARGET_URL ||
      ''
    ).trim();

    if (!pingTarget) {
      sendJson(req, res, 400, {error: 'Missing target. Use ?target=https://sas-host or X-SAS-Target header'});
      return;
    }

    const normalizedPing = normalizeTargetValue(pingTarget);
    if (!normalizedPing) {
      sendJson(req, res, 400, {error: 'Invalid target URL'});
      return;
    }

    let pingUrl;
    try {
      pingUrl = new URL(normalizedPing);
    } catch (_) {
      sendJson(req, res, 400, {error: 'Could not parse target URL'});
      return;
    }

    const pingClient = pingUrl.protocol === 'https:' ? https : http;
    const started = Date.now();

    const pingReq = pingClient.request(
      {
        protocol: pingUrl.protocol,
        hostname: pingUrl.hostname,
        port: pingUrl.port || (pingUrl.protocol === 'https:' ? 443 : 80),
        path: '/admin/api/index.php/api/login',
        method: 'OPTIONS',
        headers: {'user-agent': 'NetAgent-Proxy-PingTest/1.0'},
        timeout: 8000,
      },
      (pingRes) => {
        pingRes.resume();
        sendJson(req, res, 200, {
          ok: true,
          target: pingUrl.origin,
          httpStatus: pingRes.statusCode,
          latencyMs: Date.now() - started,
          note: 'OPTIONS request to /admin/api/index.php/api/login',
        });
      }
    );

    pingReq.on('timeout', () => {
      pingReq.destroy();
      sendJson(req, res, 504, {ok: false, target: pingUrl.origin, error: 'Timeout after 8s'});
    });

    pingReq.on('error', (err) => {
      sendJson(req, res, 502, {ok: false, target: pingUrl.origin, error: err.message, code: err.code});
    });

    pingReq.end();
    return;
  }

  if (parsedHealthUrl.pathname === '/send-message') {
    if (req.method !== 'POST') {
      sendJson(req, res, 405, {error: 'Method Not Allowed'});
      return;
    }

    (async () => {
      try {
        const body = await readJsonBody(req, MAX_BODY_BYTES);
        const to = String(body.to || '').trim();
        const message = String(body.message || '').trim();
        const templateName = String(body.templateName || '').trim();
        const language = String(body.language || 'ar').trim() || 'ar';
        const parameters = Array.isArray(body.parameters) ? body.parameters : [];
        const clientBuild = String(body.clientBuild || 'legacy').trim() || 'legacy';
        const templateVariables = body.templateVariables && typeof body.templateVariables === 'object'
          ? body.templateVariables
          : {};

        console.log('[send-message] incoming payload:', JSON.stringify({
          to,
          hasMessage: message.length > 0,
          templateName,
          language,
          parametersCount: parameters.length,
          templateVariables: Object.keys(templateVariables),
          clientBuild,
        }));

        if (clientBuild === 'legacy') {
          sendJson(req, res, 409, {
            success: false,
            error: 'The web app is outdated. Reload it after the latest Netlify deployment.',
            requiredClientBuild: 'whatsapp-template-v3',
          });
          return;
        }

        if (!to) {
          sendJson(req, res, 400, {error: '"to" is required'});
          return;
        }

        const apiResult = templateName
          ? await sendWhatsAppTemplate(to, templateName, language, parameters, templateVariables)
          : await sendWhatsAppText(to, message);
        const messageId = apiResult?.messages?.[0]?.id || apiResult?.message_id || '';

        sendJson(req, res, 200, {
          success: true,
          messageId,
        });
      } catch (error) {
        const status = Number(error?.statusCode) || 500;
        const payload = {
          success: false,
          error: error?.message || 'Internal Server Error',
        };

        if (error && error.details !== undefined) {
          payload.details = error.details;
        }

        sendJson(req, res, status, payload);
      }
    })();
    return;
  }

  if (!DISABLE_PROXY_AUTH && !hasValidProxyToken(req)) {
    const hasXProxy = String(req.headers['x-proxy-token'] || '').trim().length > 0;
    const hasXSasProxy = String(req.headers['x-sas-proxy-token'] || '').trim().length > 0;
    const hasApiKey = String(req.headers['x-api-key'] || '').trim().length > 0;
    const hasBearer = String(req.headers.authorization || '').toLowerCase().startsWith('bearer ');
    console.warn(
      `[auth] 401 ${req.method} ${req.url} tokenHeaders: x-proxy-token=${hasXProxy} x-sas-proxy-token=${hasXSasProxy} x-api-key=${hasApiKey} bearer=${hasBearer}`
    );
    sendJson(req, res, 401, {error: 'Unauthorized'});
    return;
  }

  if (parsedHealthUrl.pathname === '/whatsapp/template-contract') {
    if (req.method !== 'GET') {
      sendJson(req, res, 405, {error: 'Method Not Allowed'});
      return;
    }

    (async () => {
      try {
        const templateName = String(
          parsedHealthUrl.searchParams.get('name') || ''
        ).trim();
        const language = String(
          parsedHealthUrl.searchParams.get('language') || 'ar'
        ).trim() || 'ar';
        const accessToken = WHATSAPP_ACCESS_TOKEN || WHATSAPP_TOKEN;
        const phoneNumberId = WHATSAPP_PHONE_NUMBER_ID || PHONE_NUMBER_ID;

        if (!templateName) {
          sendJson(req, res, 400, {error: 'Template name is required'});
          return;
        }
        if (!phoneNumberId || !accessToken) {
          sendJson(req, res, 500, {error: 'Missing WhatsApp configuration'});
          return;
        }

        templateContractCache.delete(`${templateName}:${language}`);
        const contract = await getApprovedTemplateContract(
          templateName,
          language,
          phoneNumberId,
          accessToken
        );
        sendJson(req, res, 200, {
          templateName,
          language,
          parameterNames: contract.names,
          bodyText: contract.bodyText,
        });
      } catch (error) {
        const status = Number(error?.statusCode) || 500;
        const payload = {error: error?.message || 'Internal Server Error'};
        if (error && error.details !== undefined) {
          payload.details = error.details;
        }
        sendJson(req, res, status, payload);
      }
    })();
    return;
  }

  if (parsedHealthUrl.pathname === '/whatsapp/send') {
    if (req.method !== 'POST') {
      sendJson(req, res, 405, {error: 'Method Not Allowed'});
      return;
    }

    (async () => {
      try {
        const body = await readJsonBody(req, MAX_BODY_BYTES);
        const to = String(body.to || '').trim();
        const message = String(body.message || '').trim();
        const templateName = String(body.templateName || '').trim();
        const language = String(body.language || 'ar').trim() || 'ar';
        const parameters = Array.isArray(body.parameters) ? body.parameters : [];
        const clientBuild = String(body.clientBuild || 'legacy').trim() || 'legacy';
        const templateVariables = body.templateVariables && typeof body.templateVariables === 'object'
          ? body.templateVariables
          : {};

        console.log('[whatsapp/send] incoming payload:', JSON.stringify({
          to,
          hasMessage: message.length > 0,
          templateName,
          language,
          parametersCount: parameters.length,
          templateVariables: Object.keys(templateVariables),
          clientBuild,
        }));

        if (clientBuild === 'legacy') {
          sendJson(req, res, 409, {
            error: 'The web app is outdated. Reload it after the latest Netlify deployment.',
            requiredClientBuild: 'whatsapp-template-v3',
          });
          return;
        }

        if (!to) {
          sendJson(req, res, 400, {error: '"to" is required'});
          return;
        }

        const apiResult = templateName
          ? await sendWhatsAppTemplate(to, templateName, language, parameters, templateVariables)
          : await sendWhatsAppText(to, message);
        sendJson(req, res, 200, apiResult);
      } catch (error) {
        const status = Number(error?.statusCode) || 500;
        const payload = {error: error?.message || 'Internal Server Error'};

        if (error && error.details !== undefined) {
          payload.details = error.details;
        }

        sendJson(req, res, status, payload);
      }
    })();
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

  console.log(`[proxy] ${req.method} ${req.url} → ${targetBaseUrl.origin}`);

  const upstreamClient = targetBaseUrl.protocol === 'https:' ? https : http;
  const upstreamHeaders = buildUpstreamHeaders(req);
  const upstreamPath = buildUpstreamPath(targetBaseUrl, sasPath);

  const bodyChunks = [];
  let bodyBytes = 0;
  let bodyTooLarge = false;

  req.on('data', (chunk) => {
    if (bodyTooLarge) return;
    bodyBytes += chunk.length;
    if (bodyBytes > MAX_BODY_BYTES) {
      bodyTooLarge = true;
      sendJson(req, res, 413, {
        error: 'Payload too large',
        limit: MAX_BODY_BYTES,
      });
      return;
    }
    bodyChunks.push(chunk);
  });

  req.on('error', (error) => {
    if (!res.headersSent) {
      sendJson(req, res, 400, {error: 'Failed to read request body', message: error.message});
    }
  });

  req.on('end', () => {
    if (bodyTooLarge || res.headersSent) return;

    const requestBody = bodyChunks.length > 0 ? Buffer.concat(bodyChunks) : Buffer.alloc(0);
    const pathCandidates = buildPathCandidates(upstreamPath);
    const waPhoneHeader = String(req.headers['x-wa-phone'] || '').replace(/\D/g, '').trim();
    const waMessage = decodeBase64Utf8(req.headers['x-wa-message-b64']);

    const forwardAttempt = (index) => {
      const currentPath = pathCandidates[index];
      const headers = {...upstreamHeaders};
      if (requestBody.length > 0) {
        headers['content-length'] = String(requestBody.length);
      } else {
        delete headers['content-length'];
      }

      const upstream = upstreamClient.request(
        {
          protocol: targetBaseUrl.protocol,
          hostname: targetBaseUrl.hostname,
          port: targetBaseUrl.port || (targetBaseUrl.protocol === 'https:' ? 443 : 80),
          path: currentPath,
          method: req.method,
          headers,
          timeout: 30000,
        },
        (upstreamRes) => {
          const status = upstreamRes.statusCode || 0;
          const canRetry = index + 1 < pathCandidates.length;

          // Retry API base variants when upstream route does not exist.
          if (canRetry && (status === 404 || status === 405)) {
            upstreamRes.resume();
            forwardAttempt(index + 1);
            return;
          }

          res.setHeader('X-Proxy-Target', targetBaseUrl.origin);
          res.setHeader('X-Proxy-Path', currentPath);
          res.setHeader('X-Proxy-Attempt', String(index + 1));

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
          if (status >= 400 && contentType.includes('text/html')) {
            handleHtmlError(req, res, upstreamRes, targetBaseUrl, currentPath);
            return;
          }

          const shouldSendActivationWhatsapp =
            isActivationPath(currentPath) &&
            req.method === 'POST' &&
            waPhoneHeader.length > 0 &&
            waMessage.length > 0;

          if (shouldSendActivationWhatsapp) {
            const chunks = [];
            upstreamRes.on('data', (chunk) => chunks.push(chunk));
            upstreamRes.on('end', async () => {
              const bodyBuffer = Buffer.concat(chunks);
              const bodyText = bodyBuffer.toString('utf8');

              res.writeHead(status || 502);
              res.end(bodyBuffer);

              if (!activationSucceeded(status, bodyText)) {
                return;
              }

              try {
                await sendWhatsApp(waPhoneHeader, waMessage);
                console.log(`[proxy] activation WhatsApp sent to ${waPhoneHeader}`);
              } catch (err) {
                console.error(`[proxy] activation WhatsApp failed for ${waPhoneHeader}: ${err.message}`);
              }
            });
            return;
          }

          res.writeHead(status || 502);
          upstreamRes.pipe(res);
        }
      );

      upstream.on('timeout', () => {
        upstream.destroy(new Error('Upstream timeout'));
      });

      upstream.on('error', (error) => {
        console.error(`[proxy] upstream error → ${targetBaseUrl.origin}${currentPath}: ${error.message}`);
        const canRetry = index + 1 < pathCandidates.length;
        if (canRetry) {
          forwardAttempt(index + 1);
          return;
        }

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

      if (requestBody.length > 0) {
        upstream.write(requestBody);
      }
      upstream.end();
    };

    forwardAttempt(0);
  });
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
