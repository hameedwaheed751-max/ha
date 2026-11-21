// Run: start the RTDB emulator on port 9123
//   java -jar ~/.cache/firebase/emulators/firebase-database-emulator-v4.11.2.jar --port 9123
// then: node tool/trial_claims_rules_test.mjs database.rules.json
// Tests the trialClaims rules (anti-trial-abuse fingerprints) against the
// local RTDB emulator, covering the added earthlink/fiberx kinds.
import { readFileSync } from 'node:fs';

const BASE = process.env.EMU_BASE || 'http://127.0.0.1:9123';
const NS = 'rulestest';
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

const hex = (c) => c.repeat(64);
const claim = (uid) => ({ uid, at: 1762000000000 });

const rules = readFileSync(rulesPath, 'utf8');
const s = await fetch(`${BASE}/.settings/rules.json?ns=${NS}`, {
  method: 'PUT', headers: { Authorization: 'Bearer owner' }, body: rules,
});
if (!s.ok) { console.log('rules load failed', s.status, await s.text()); process.exit(1); }

// seed two agent profiles as owner (bypasses rules)
await req('PUT', '', 'owner', {
  agents: {
    agentA: { profile: { email: 'a@x.iq' } },
    agentB: { profile: { email: 'b@x.iq' } },
  },
});

// an agent registers a fingerprint for each allowed kind → all allowed
await check('agent claims phones', true,
  req('PUT', `trialClaims/phones/${hex('1')}`, 'agentA', claim('agentA')));
await check('agent claims sas (RADIUS)', true,
  req('PUT', `trialClaims/sas/${hex('2')}`, 'agentA', claim('agentA')));
await check('agent claims ftth', true,
  req('PUT', `trialClaims/ftth/${hex('3')}`, 'agentA', claim('agentA')));
await check('agent claims earthlink (NEW)', true,
  req('PUT', `trialClaims/earthlink/${hex('4')}`, 'agentA', claim('agentA')));
await check('agent claims fiberx (NEW)', true,
  req('PUT', `trialClaims/fiberx/${hex('5')}`, 'agentA', claim('agentA')));

// an unknown kind is rejected by the $kind validate
await check('unknown kind rejected', false,
  req('PUT', `trialClaims/bogus/${hex('6')}`, 'agentA', claim('agentA')));

// a non-64-hex hash is rejected by the $hash validate
await check('non-hex hash rejected', false,
  req('PUT', `trialClaims/earthlink/not-hex`, 'agentA', claim('agentA')));

// missing required field (at) is rejected
await check('missing at rejected', false,
  req('PUT', `trialClaims/fiberx/${hex('7')}`, 'agentA', { uid: 'agentA' }));

// another agent cannot overwrite an existing fingerprint owned by agentA
await check('other agent cannot steal earthlink claim', false,
  req('PUT', `trialClaims/earthlink/${hex('4')}`, 'agentB', claim('agentB')));

// an unauthenticated write is rejected
await check('unauthenticated claim rejected', false,
  req('PUT', `trialClaims/fiberx/${hex('8')}`, null, claim('agentA')));

// the owner of a fingerprint may re-write it (idempotent re-claim)
await check('owner re-claims own earthlink', true,
  req('PUT', `trialClaims/earthlink/${hex('4')}`, 'agentA', claim('agentA')));

console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
