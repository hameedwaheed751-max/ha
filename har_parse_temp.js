const fs = require('fs');
const path = 'C:/Users/Hamwdy2/Desktop/sas.jt.iq000.har';
const text = fs.readFileSync(path, 'utf8');
const data = JSON.parse(text);
const entries = ((data.log || {}).entries) || [];
let found = 0;
for (let i = 0; i < entries.length; i++) {
  const req = entries[i].request || {};
  const url = req.url || '';
  if (url.includes('/admin/api/index.php/api/login')) {
    found++;
    console.log('ENTRY', i);
    console.log('URL', url);
    console.log('METHOD', req.method);
    console.log('HTTP', req.httpVersion);
    console.log('HEADERS');
    (req.headers || []).forEach((h) => console.log(' ', h.name, ':', h.value));
    const pd = req.postData;
    if (pd) {
      console.log('POSTDATA mimeType', pd.mimeType);
      if (pd.text) {
        console.log('POST DATA TEXT', pd.text.slice(0, 2000));
      }
    }
    const res = entries[i].response || {};
    console.log('RESPONSE STATUS', res.status, res.statusText);
    console.log('RESPONSE HEADERS');
    (res.headers || []).forEach((h) => console.log(' ', h.name, ':', h.value));
    console.log('----');
  }
}
console.log('FOUND', found);
