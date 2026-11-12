// Run: start the RTDB emulator on port 9123
//   java -jar ~/.cache/firebase/emulators/firebase-database-emulator-v4.11.2.jar --port 9123
// then: node tool/store_rules_test.mjs database.rules.json
// Tests the `stores` (المشتريات) rules against the local RTDB emulator.
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

const S = 'stores';

// a store owned by a1
const store = (extra = {}) => ({
  name: 'متجر شمس',
  url: 'https://shams-ftth.vercel.app',
  ownerUid: 'a1',
  ownerName: 'مكتب شمس',
  approved: false,
  updatedAt: 1762000000000,
  ...extra,
});

const rules = readFileSync(rulesPath, 'utf8');
let s = await fetch(`${BASE}/.settings/rules.json?ns=${NS}`, {
  method: 'PUT', headers: { Authorization: 'Bearer owner' }, body: rules,
});
if (!s.ok) { console.log('rules load failed', s.status, await s.text()); process.exit(1); }

// seed agents + one existing store owned by a1 (as owner, bypasses rules)
await req('PUT', '', 'owner', {
  agents: {
    a1: { profile: { role: 'agent' } },
    a2: { profile: { role: 'agent' } },
    pending: { profile: { firstName: 'x' } },
  },
  stores: { existing: store() },
});

// reads
await check('agent reads stores', true, req('GET', S, 'a1'));
await check('admin reads stores', true, req('GET', S, ADMIN));
await check('non-agent cannot read stores', false, req('GET', S, 'pending'));
await check('signed-out cannot read stores', false, req('GET', S, null));

// agent writes own store
await check('agent adds own store (approved:false)', true, req('PUT', `${S}/k1`, 'a1', store()));
await check('agent cannot self-approve', false, req('PUT', `${S}/k2`, 'a1', store({ approved: true })));
await check('agent cannot write someone else store', false, req('PUT', `${S}/k3`, 'a1', store({ ownerUid: 'a2' })));
await check('agent cannot write non-https url', false, req('PUT', `${S}/k4`, 'a1', store({ url: 'http://x.com' })));
await check('agent cannot write javascript url', false, req('PUT', `${S}/k5`, 'a1', store({ url: 'javascript:alert(1)' })));
await check('name over 80 chars rejected', false, req('PUT', `${S}/k6`, 'a1', store({ name: 'ش'.repeat(81) })));
await check('unknown field rejected', false, req('PUT', `${S}/k7`, 'a1', store({ junk: 1 })));
await check('missing ownerName rejected', false, req('PUT', `${S}/k8`, 'a1',
  { name: 'x', url: 'https://x.com', ownerUid: 'a1', approved: false, updatedAt: 1 }));
await check('non-agent cannot write', false, req('PUT', `${S}/k9`, 'pending', store()));

// ownership: a2 cannot touch a1's existing store; a1 can delete own
await check('agent cannot overwrite another agent store', false, req('PUT', `${S}/existing`, 'a2', store({ ownerUid: 'a2' })));
await check('owner deletes own store', true, req('DELETE', `${S}/k1`, 'a1'));

// admin moderation
await check('admin approves a store', true, req('PUT', `${S}/existing/approved`, ADMIN, true));
await check('admin deletes any store', true, req('DELETE', `${S}/existing`, ADMIN));

console.log(failures === 0 ? '\nALL PASSED' : `\n${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
