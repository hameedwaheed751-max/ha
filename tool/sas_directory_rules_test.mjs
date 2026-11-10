// Run: start the RTDB emulator on port 9123
//   java -jar ~/.cache/firebase/emulators/firebase-database-emulator-v4.11.2.jar --port 9123
// then: node tool/sas_directory_rules_test.mjs database.rules.json
// Tests the sasDirectory rules against the local RTDB emulator.
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

const KEY = 'a'.repeat(64);      // مفتاح صالح (64 hex) لمدخل عادي
const SEEDKEY = 'b'.repeat(64);  // مفتاح مدخل جاهز يزرعه المالك
const BADKEY = 'not-hex-key';

const entry = (extra = {}) => ({
  company: 'سبيد نت',
  serverUrl: 'https://sas.speednet-iq.com',
  host: 'sas.speednet-iq.com',
  seed: false,
  updatedAt: 1762000000000,
  ...extra,
});

const rules = readFileSync(rulesPath, 'utf8');
let s = await fetch(`${BASE}/.settings/rules.json?ns=${NS}`, {
  method: 'PUT', headers: { Authorization: 'Bearer owner' }, body: rules,
});
if (!s.ok) { console.log('rules load failed', s.status, await s.text()); process.exit(1); }

// seed agents + one protected seed entry as owner (bypasses rules)
await req('PUT', '', 'owner', {
  agents: {
    a1: { profile: { role: 'agent' } },
    pending: { profile: { firstName: 'x' } },
  },
  sasDirectory: { [SEEDKEY]: entry({ seed: true }) },
});

const D = 'sasDirectory';

// reads
await check('agent reads directory', true, req('GET', D, 'a1'));
await check('admin reads directory', true, req('GET', D, ADMIN));
await check('non-agent cannot read directory', false, req('GET', D, 'pending'));
await check('signed-out cannot read directory', false, req('GET', D, null));

// agent writes
await check('agent adds a valid company', true, req('PUT', `${D}/${KEY}`, 'a1', entry()));
await check('agent cannot write seed:true', false, req('PUT', `${D}/${'c'.repeat(64)}`, 'a1', entry({ seed: true })));
await check('agent cannot omit host', false, req('PUT', `${D}/${'d'.repeat(64)}`, 'a1',
  { company: 'x', serverUrl: 'https://x.com', seed: false, updatedAt: 1 }));
await check('agent cannot add unknown field', false, req('PUT', `${D}/${'e'.repeat(64)}`, 'a1', entry({ junk: 1 })));
await check('company over 80 chars rejected', false, req('PUT', `${D}/${'f'.repeat(64)}`, 'a1', entry({ company: 'ش'.repeat(81) })));
await check('non-hex key rejected', false, req('PUT', `${D}/${BADKEY}`, 'a1', entry()));
await check('agent cannot overwrite a seed entry', false, req('PUT', `${D}/${SEEDKEY}`, 'a1', entry()));
await check('agent cannot delete an entry', false, req('DELETE', `${D}/${KEY}`, 'a1'));
await check('non-agent cannot write', false, req('PUT', `${D}/${'1'.repeat(64)}`, 'pending', entry()));

// admin writes
await check('admin writes a seed entry', true, req('PUT', `${D}/${'2'.repeat(64)}`, ADMIN, entry({ seed: true })));
await check('admin can overwrite a seed entry', true, req('PUT', `${D}/${SEEDKEY}`, ADMIN, entry({ seed: true, company: 'سبيد نت ٢' })));
await check('admin deletes an entry', true, req('DELETE', `${D}/${KEY}`, ADMIN));

console.log(failures === 0 ? '\nALL PASSED' : `\n${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
