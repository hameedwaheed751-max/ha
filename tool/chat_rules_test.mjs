// Run: start the RTDB emulator on port 9123
//   java -jar ~/.cache/firebase/emulators/firebase-database-emulator-v4.11.2.jar --port 9123
// then: node tool/chat_rules_test.mjs database.rules.json
// Tests the chat rules in database.rules.json against the local RTDB emulator.
import { readFileSync } from 'node:fs';

const BASE = 'http://127.0.0.1:9123';
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

const msg = (uid, extra = {}) => ({
  senderName: uid === ADMIN ? 'الإدارة' : `وكيل ${uid}`,
  senderEmail: `${uid}@x.iq`,
  senderUid: uid,
  text: 'مرحبا',
  sentAt: '2026-11-08T10:00:00.000',
  deletedByAdmin: false,
  ...extra,
});

// Load rules and seed agents as the owner (bypasses rules).
const rules = readFileSync(rulesPath, 'utf8');
let s = await fetch(`${BASE}/.settings/rules.json?ns=${NS}`, {
  method: 'PUT', headers: { Authorization: 'Bearer owner' }, body: rules,
});
if (!s.ok) { console.log('rules load failed', s.status, await s.text()); process.exit(1); }
await req('PUT', '', 'owner', {
  agents: {
    a1: { profile: { role: 'agent' } },
    a2: { profile: { role: 'agent' } },
    pending: { profile: { firstName: 'x' } },
  },
  global_chat: { chat: { m2: msg('a2'), old: { senderName: 'قديم', text: 'x', sentAt: 's' } } },
});

const C = 'global_chat/chat';
await check('agent reads chat', true, req('GET', C, 'a1'));
await check('admin reads chat', true, req('GET', C, ADMIN));
await check('signed-in non-agent cannot read chat', false, req('GET', C, 'pending'));
await check('signed-out cannot read chat', false, req('GET', C, null));

await check('agent sends own message', true, req('PUT', `${C}/m1`, 'a1', msg('a1')));
await check('agent sends a reply with quote', true, req('PUT', `${C}/m1r`, 'a1',
  msg('a1', { replyTo: { id: 'm2', senderName: 'وكيل a2', senderUid: 'a2', text: 'مرحبا' } })));
await check('agent sends image message', true, req('PUT', `${C}/m1i`, 'a1',
  msg('a1', { text: '', imageUrl: 'https://firebasestorage.googleapis.com/v0/b/x/o/chat%2F1.jpg' })));
await check('non-agent cannot send', false, req('PUT', `${C}/p1`, 'pending', msg('pending')));
await check('cannot send as another agent', false, req('PUT', `${C}/f1`, 'a1', msg('a2')));
await check('cannot overwrite another agent message', false, req('PUT', `${C}/m2`, 'a1', msg('a1')));
await check('cannot edit another agent message', false, req('PATCH', `${C}/m2`, 'a1', { text: 'تغيير' }));
await check('cannot delete another agent message', false, req('DELETE', `${C}/m2`, 'a1'));
await check('cannot soft-delete another agent message', false, req('PATCH', `${C}/m2`, 'a1',
  { deletedAt: '2026-11-08T11:00:00', deletedByUid: 'a1', deletedByAdmin: false }));

await check('agent edits own message', true, req('PATCH', `${C}/m1`, 'a1',
  { text: 'معدلة', editedAt: '2026-11-08T10:05:00' }));
await check('agent cannot rename own message', false, req('PATCH', `${C}/m1`, 'a1', { senderName: 'المدير' }));
await check('agent cannot change own message time', false, req('PATCH', `${C}/m1`, 'a1', { sentAt: '2020-01-01' }));
await check('agent soft-deletes own message', true, req('PATCH', `${C}/m1`, 'a1',
  { deletedAt: '2026-11-08T11:00:00', deletedByUid: 'a1', deletedByAdmin: false }));
await check('agent cannot claim admin deletion', false, req('PATCH', `${C}/m1i`, 'a1',
  { deletedAt: '2026-11-08T11:00:00', deletedByUid: 'a1', deletedByAdmin: true }));
await check('agent cannot hard-delete own message', false, req('DELETE', `${C}/m1i`, 'a1'));

await check('text over 2000 chars rejected', false, req('PUT', `${C}/big`, 'a1', msg('a1', { text: 'x'.repeat(2001) })));
await check('text of 2000 chars allowed', true, req('PUT', `${C}/max`, 'a1', msg('a1', { text: 'x'.repeat(2000) })));
await check('foreign image link rejected', false, req('PUT', `${C}/img`, 'a1', msg('a1', { imageUrl: 'https://evil.example/x.jpg' })));
await check('unknown field rejected', false, req('PUT', `${C}/extra`, 'a1', msg('a1', { junk: 1 })));
await check('missing sender rejected', false, req('PUT', `${C}/nos`, 'a1', { senderUid: 'a1', text: 'x', sentAt: 's' }));

await check('admin sends message', true, req('PUT', `${C}/ad1`, ADMIN, msg(ADMIN)));
await check('admin soft-deletes agent message', true, req('PATCH', `${C}/m2`, ADMIN,
  { deletedAt: '2026-11-08T12:00:00', deletedByUid: ADMIN, deletedByAdmin: true }));
await check('admin removes a message', true, req('DELETE', `${C}/m1r`, ADMIN));
await check('admin clears an old message without senderUid', true, req('DELETE', `${C}/old`, ADMIN));

console.log(failures === 0 ? '\nALL PASSED' : `\n${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);
