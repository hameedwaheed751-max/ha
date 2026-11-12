// Run: start the RTDB emulator on port 9123, then:
//   node tool/product_rules_test.mjs database.rules.json
// Tests the `products` (store device listings) rules + optional stores.url.
import { readFileSync } from 'node:fs';

const BASE = process.env.EMU_BASE || 'http://127.0.0.1:9123';
const NS = 'rulestest';
const ADMIN = 'wE10WciDVudIOJziBurjhBxpDfO2';
const rulesPath = process.argv[2];

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
const token = (uid) => uid === 'owner' ? 'owner' :
  `${b64({ alg: 'none', kid: 'fakekid', typ: 'JWT' })}.${b64({
    uid, sub: uid, user_id: uid, iat: 1, exp: 9999999999, auth_time: 1,
    firebase: { sign_in_provider: 'password', identities: {} },
    aud: 'rulestest', iss: 'https://securetoken.google.com/rulestest',
  })}.`;

async function req(method, path, uid, body) {
  const headers = {};
  let auth = '';
  if (uid === 'owner') headers.Authorization = 'Bearer owner';
  else if (uid) auth = `&auth=${token(uid)}`;
  const res = await fetch(`${BASE}/${path}.json?ns=${NS}${auth}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  return res.status;
}

let failures = 0;
async function check(name, expectOk, promise) {
  const status = await promise;
  const ok = status >= 200 && status < 300;
  const pass = ok === expectOk;
  if (!pass) failures++;
  console.log(`${pass ? 'PASS' : 'FAIL'} ${name} (HTTP ${status}, expected ${expectOk ? 'allowed' : 'denied'})`);
}

const P = 'products';
const S = 'stores';

const product = (extra = {}) => ({
  storeKey: 's1',
  ownerUid: 'a1',
  ownerName: 'مكتب شمس',
  description: 'راوتر TP-Link بحالة ممتازة',
  images: { '0': 'https://cdn.example.com/a.jpg' },
  updatedAt: 1762000000000,
  ...extra,
});

const rules = readFileSync(rulesPath, 'utf8');
let s = await fetch(`${BASE}/.settings/rules.json?ns=${NS}`, {
  method: 'PUT', headers: { Authorization: 'Bearer owner' }, body: rules,
});
if (!s.ok) { console.log('rules load failed', s.status, await s.text()); process.exit(1); }

// seed agents + one existing product owned by a1 (as owner, bypasses rules)
await req('PUT', '', 'owner', {
  agents: {
    a1: { profile: { role: 'agent' } },
    a2: { profile: { role: 'agent' } },
    pending: { profile: { firstName: 'x' } },
  },
  products: { existing: product() },
});

// reads
await check('agent reads products', true, req('GET', P, 'a1'));
await check('admin reads products', true, req('GET', P, ADMIN));
await check('non-agent cannot read products', false, req('GET', P, 'pending'));
await check('signed-out cannot read products', false, req('GET', P, null));

// agent writes own product
await check('agent adds own product', true, req('PUT', `${P}/p1`, 'a1', product()));
await check('agent cannot write another owner product', false, req('PUT', `${P}/p2`, 'a1', product({ ownerUid: 'a2' })));
await check('missing description rejected', false, req('PUT', `${P}/p3`, 'a1',
  { storeKey: 's1', ownerUid: 'a1', ownerName: 'x', images: { '0': 'https://x/a.jpg' }, updatedAt: 1 }));
await check('empty images rejected', false, req('PUT', `${P}/p4`, 'a1',
  { storeKey: 's1', ownerUid: 'a1', ownerName: 'x', description: 'd', updatedAt: 1 }));
await check('non-https image rejected', false, req('PUT', `${P}/p5`, 'a1', product({ images: { '0': 'http://x/a.jpg' } })));
await check('6th image (index 5) rejected', false, req('PUT', `${P}/p6`, 'a1', product({
  images: { '0': 'https://x/0.jpg', '1': 'https://x/1.jpg', '2': 'https://x/2.jpg', '3': 'https://x/3.jpg', '4': 'https://x/4.jpg', '5': 'https://x/5.jpg' },
})));
await check('5 images allowed', true, req('PUT', `${P}/p6b`, 'a1', product({
  images: { '0': 'https://x/0.jpg', '1': 'https://x/1.jpg', '2': 'https://x/2.jpg', '3': 'https://x/3.jpg', '4': 'https://x/4.jpg' },
})));
await check('description over 500 rejected', false, req('PUT', `${P}/p7`, 'a1', product({ description: 'ش'.repeat(501) })));
await check('negative price rejected', false, req('PUT', `${P}/p8`, 'a1', product({ price: -5 })));
await check('valid price allowed', true, req('PUT', `${P}/p8b`, 'a1', product({ price: 25000, currency: 'د.ع' })));
await check('unknown field rejected', false, req('PUT', `${P}/p9`, 'a1', product({ junk: 1 })));
await check('non-agent cannot write', false, req('PUT', `${P}/p10`, 'pending', product()));

// ownership
await check('agent cannot overwrite another agent product', false, req('PUT', `${P}/existing`, 'a2', product({ ownerUid: 'a2' })));
await check('owner deletes own product', true, req('DELETE', `${P}/p1`, 'a1'));

// admin
await check('admin deletes any product', true, req('DELETE', `${P}/existing`, ADMIN));

// stores are external-link directory entries: url is required
await check('agent adds a store WITHOUT url is rejected', false, req('PUT', `${S}/${'a'.repeat(20)}`, 'a1',
  { name: 'متجري', ownerUid: 'a1', ownerName: 'مكتب', approved: false, updatedAt: 1 }));
await check('agent adds a store WITH https url', true, req('PUT', `${S}/${'a'.repeat(20)}`, 'a1',
  { name: 'متجري', url: 'https://shop.example.com', ownerUid: 'a1', ownerName: 'مكتب', approved: false, updatedAt: 1 }));
await check('store with non-https url still rejected', false, req('PUT', `${S}/${'b'.repeat(20)}`, 'a1',
  { name: 'متجري', url: 'http://x.com', ownerUid: 'a1', ownerName: 'مكتب', approved: false, updatedAt: 1 }));

console.log(failures === 0 ? '\nALL PASSED' : `\n${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
