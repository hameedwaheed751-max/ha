// Loaded into the test proxy so that it never reaches Meta or any other host.
globalThis.fetch = async (input, init = {}) => {
  const url = String(input);
  const json = (body) =>
    new Response(JSON.stringify(body), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  if (!url.startsWith('https://graph.facebook.com/')) {
    throw new Error(`Blocked outbound request: ${url}`);
  }
  if (init.method === 'POST' && url.endsWith('/messages')) {
    return json({ messages: [{ id: 'wamid.test-message' }] });
  }
  if (url.includes('/message_templates')) {
    return json({
      data: [
        {
          name: 'debt_paid',
          language: 'ar',
          status: 'APPROVED',
          parameter_format: 'NAMED',
          components: [
            {
              type: 'BODY',
              text: 'مرحبا {{customer_name}}',
              example: {
                body_text_named_params: [
                  { param_name: 'customer_name', example: 'علي' },
                ],
              },
            },
          ],
        },
      ],
    });
  }
  return json({});
};
