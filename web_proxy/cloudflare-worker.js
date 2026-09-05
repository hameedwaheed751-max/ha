const SAS_ORIGIN = 'https://sas.jt.iq';
const PROXY_TOKEN = '104199';

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET,POST,PUT,PATCH,DELETE,OPTIONS',
    'Access-Control-Allow-Headers':
      'Content-Type, Authorization, Allow-Cache-Y, X-SAS-Target, X-Proxy-Token, X-SAS-Proxy-Token, X-API-Key, X-SAS-DIAG',
  };
}

function withCors(response) {
  const headers = new Headers(response.headers);
  headers.delete('access-control-allow-origin');
  headers.delete('access-control-allow-credentials');
  for (const [key, value] of Object.entries(corsHeaders())) {
    headers.set(key, value);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      ...corsHeaders(),
    },
  });
}

async function proxyRequest(request) {
  const url = new URL(request.url);

  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  if (url.pathname === '/' || url.pathname === '/health' || url.pathname === '/healthz') {
    return json({ ok: true, service: 'NetAgent SAS Proxy', runtime: 'cloudflare-workers' });
  }

  if (!url.pathname.startsWith('/sas/')) {
    return new Response('NetAgent SAS Proxy', {
      status: 404,
      headers: {
        'Content-Type': 'text/plain; charset=utf-8',
        ...corsHeaders(),
      },
    });
  }

  const suppliedToken =
    request.headers.get('X-Proxy-Token') ||
    request.headers.get('X-SAS-Proxy-Token') ||
    request.headers.get('X-API-Key');
  if (suppliedToken !== PROXY_TOKEN) {
    return json({ error: 'Unauthorized' }, 401);
  }

  const requestedOrigin = (request.headers.get('X-SAS-Target') || '').replace(/\/+$/, '');
  if (requestedOrigin && requestedOrigin !== SAS_ORIGIN) {
    return json({ error: 'SAS target is not allowed' }, 403);
  }

  let targetUrl;
  try {
    targetUrl = new URL(SAS_ORIGIN + url.pathname.substring(4) + url.search);
  } catch (error) {
    return json({ error: 'Invalid SAS target' }, 400);
  }

  const headers = new Headers(request.headers);
  headers.delete('Host');
  headers.delete('Origin');
  headers.delete('Referer');
  headers.delete('X-SAS-Target');
  headers.delete('X-Proxy-Token');
  headers.delete('X-SAS-Proxy-Token');
  headers.delete('X-API-Key');
  headers.delete('X-SAS-DIAG');

  const init = {
    method: request.method,
    headers,
    redirect: 'manual',
  };

  if (!['GET', 'HEAD'].includes(request.method)) {
    init.body = request.body;
  }

  try {
    const upstreamResponse = await fetch(targetUrl.toString(), init);
    return withCors(upstreamResponse);
  } catch (error) {
    return json(
      {
        error: 'SAS upstream failed',
        detail: error instanceof Error ? error.message : String(error),
      },
      502,
    );
  }
}

export default {
  fetch(request) {
    return proxyRequest(request);
  },
};
