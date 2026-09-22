const SAS_SSL_PROBLEM_HOSTS = new Set([
  'sas.speednet-iq.com',
  'reseller.nbtel.iq',
  'reseller.nbtle.iq',
  'reseller.nbtele.iq',
]);

const RENDER_PROXY_URL = 'https://netagent-sas-proxy.onrender.com';

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

function addDiagHeaders(response, hostname, protocol, upstreamStatus, errorType) {
  const headers = new Headers(response.headers);
  headers.set('X-Sas-Diag-Hostname', hostname || '');
  headers.set('X-Sas-Diag-Protocol', protocol || '');
  headers.set('X-Sas-Diag-Status', String(upstreamStatus ?? ''));
  headers.set('X-Sas-Diag-Error-Type', errorType || 'none');
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function buildDirectUpstreamHeaders(request) {
  const headers = new Headers(request.headers);
  headers.delete('Host');
  headers.delete('Origin');
  headers.delete('Referer');
  headers.delete('X-SAS-Target');
  headers.delete('X-Proxy-Token');
  headers.delete('X-SAS-Proxy-Token');
  headers.delete('X-API-Key');
  headers.delete('X-SAS-DIAG');
  return headers;
}

function buildProxyForwardHeaders(request) {
  const headers = new Headers(request.headers);
  headers.delete('Host');
  headers.delete('Origin');
  headers.delete('Referer');
  headers.delete('X-SAS-DIAG');
  return headers;
}

async function tryDirectFetch(request, targetUrl) {
  const headers = buildDirectUpstreamHeaders(request);

  const init = {
    method: request.method,
    headers,
    redirect: 'manual',
  };

  if (!['GET', 'HEAD'].includes(request.method)) {
    try {
      const bodyBuffer = await request.arrayBuffer();
      if (bodyBuffer.byteLength > 0) {
        init.body = bodyBuffer;
      }
    } catch (_) {}
  }

  return await fetch(targetUrl.toString(), init);
}

async function routeViaRenderProxy(request, targetUrl) {
  const url = new URL(request.url);
  const proxyPath = url.pathname + url.search;
  const proxyFullUrl = `${RENDER_PROXY_URL}${proxyPath}`;

  const headers = buildProxyForwardHeaders(request);

  const init = {
    method: request.method,
    headers,
    redirect: 'manual',
  };

  if (!['GET', 'HEAD'].includes(request.method)) {
    try {
      const bodyBuffer = await request.arrayBuffer();
      if (bodyBuffer.byteLength > 0) {
        init.body = bodyBuffer;
      }
    } catch (_) {}
  }

  let response;
  try {
    response = await fetch(proxyFullUrl, init);
  } catch (error) {
    return json(
      {
        error: 'Render proxy connection failed',
        detail: error instanceof Error ? error.message : String(error),
      },
      502,
    );
  }

  return response;
}

async function proxyRequest(request) {
  const url = new URL(request.url);

  if (request.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: corsHeaders() });
  }

  if (url.pathname === '/' || url.pathname === '/health' || url.pathname === '/healthz') {
    return json({ ok: true, service: 'NetAgent SAS Proxy', runtime: 'cloudflare-workers' });
  }

  if (url.pathname === '/diagnostic') {
    return handleDiagnostic(url);
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

  const targetOrigin = request.headers.get('X-SAS-Target');
  if (!targetOrigin || !/^https?:\/\//i.test(targetOrigin)) {
    return json({ error: 'Missing X-SAS-Target' }, 400);
  }

  const cleanOrigin = targetOrigin.replace(/\/+$/, '');
  let targetUrl;
  try {
    targetUrl = new URL(cleanOrigin + url.pathname.substring(4) + url.search);
  } catch (error) {
    return json({ error: 'Invalid SAS target' }, 400);
  }

  const hostname = targetUrl.hostname;
  const protocol = targetUrl.protocol.replace(':', '').toUpperCase();

  const knownProblemHost = SAS_SSL_PROBLEM_HOSTS.has(hostname);

  if (knownProblemHost) {
    let response;
    try {
      response = await routeViaRenderProxy(request, targetUrl);
    } catch (error) {
      return json(
        {
          error: 'Fallback proxy failed',
          detail: error instanceof Error ? error.message : String(error),
        },
        502,
      );
    }
    return addDiagHeaders(withCors(response), hostname, protocol, response.status, 'tls');
  }

  let directResponse;
  try {
    directResponse = await tryDirectFetch(request, targetUrl);
  } catch (error) {
    const errorMsg = error instanceof Error ? error.message : String(error);
    if (/cert|tls|ssl|verify|self-signed|expired|526|cloudflare/i.test(errorMsg)) {
      let response;
      try {
        response = await routeViaRenderProxy(request, targetUrl);
      } catch (fallbackError) {
        return json(
          {
            error: 'TLS fallback failed',
            detail: fallbackError instanceof Error ? fallbackError.message : String(fallbackError),
          },
          502,
        );
      }
      return addDiagHeaders(withCors(response), hostname, protocol, response.status, 'tls');
    }
    return json(
      {
        error: 'SAS upstream failed',
        detail: errorMsg,
      },
      502,
    );
  }

  const status = directResponse.status;

  if (status === 526) {
    let response;
    try {
      response = await routeViaRenderProxy(request, targetUrl);
    } catch (error) {
      return json(
        {
          error: 'TLS fallback failed',
          detail: error instanceof Error ? error.message : String(error),
        },
        502,
      );
    }
    return addDiagHeaders(withCors(response), hostname, protocol, response.status, 'tls');
  }

  if (status >= 300 && status < 400) {
    const location = directResponse.headers.get('Location');
    if (location) {
      try {
        const newUrl = new URL(location, targetUrl.toString());
        const redirectHostname = newUrl.hostname;
        const redirectProtocol = newUrl.protocol.replace(':', '').toUpperCase();
        let redirectResponse;
        try {
          redirectResponse = await tryDirectFetch(request, newUrl);
          return addDiagHeaders(withCors(redirectResponse), redirectHostname, redirectProtocol, redirectResponse.status, 'none');
        } catch (retryError) {
          const retryMsg = retryError instanceof Error ? retryError.message : String(retryError);
          if (/cert|tls|ssl|verify|self-signed|expired|526/i.test(retryMsg)) {
            try {
              const proxyResponse = await routeViaRenderProxy(request, newUrl);
              return addDiagHeaders(withCors(proxyResponse), redirectHostname, redirectProtocol, proxyResponse.status, 'tls');
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
  }

  return addDiagHeaders(withCors(directResponse), hostname, protocol, status, 'none');
}

async function handleDiagnostic(url) {
  const target = url.searchParams.get('target');
  if (!target) {
    return json({ error: 'Missing target. Use ?target=https://sas-host' }, 400);
  }

  let targetUrl;
  try {
    targetUrl = new URL(target);
  } catch (_) {
    return json({ error: 'Invalid target URL' }, 400);
  }

  const hostname = targetUrl.hostname;
  const protocol = targetUrl.protocol.replace(':', '').toLowerCase();

  if (SAS_SSL_PROBLEM_HOSTS.has(hostname)) {
    return json({
      hostname,
      protocol,
      httpStatus: null,
      errorType: 'tls',
      message: 'Known SSL certificate issue - routed through Render proxy',
      renderProxyNeeded: true,
    }, 200);
  }

  try {
    const headers = new Headers();
    headers.set('User-Agent', 'NetAgent-Diagnostic/1.0');
    const response = await fetch(targetUrl.toString(), {
      method: 'HEAD',
      headers,
      redirect: 'manual',
    });

    const status = response.status;
    let errorType = 'none';
    let message = 'OK';
    let renderProxyNeeded = false;

    if (status === 526) {
      errorType = 'tls';
      message = 'TLS certificate validation failed (HTTP 526)';
      renderProxyNeeded = true;
    }

    return json({
      hostname,
      protocol,
      httpStatus: status,
      errorType,
      message,
      renderProxyNeeded,
    }, 200);
  } catch (error) {
    const errorMsg = error instanceof Error ? error.message : String(error);
    const isTLS = /cert|tls|ssl|verify|self-signed|expired|526/i.test(errorMsg);
    return json({
      hostname,
      protocol,
      httpStatus: null,
      errorType: isTLS ? 'tls' : 'connection',
      message: errorMsg,
      renderProxyNeeded: true,
    }, 200);
  }
}

export default {
  fetch(request) {
    return proxyRequest(request);
  },
};
