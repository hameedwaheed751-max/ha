# قسم «المشتريات» (Agent Stores Directory) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let any agent register their own device-selling store so it appears (after admin approval) in a new «المشتريات» tab that other agents browse and open in-app.

**Architecture:** Reuse the `sasDirectory` pattern end-to-end: a Firebase RTDB node `stores/{pushId}` holding public store info (no credentials), rules modeled on the `sasDirectory` block, a `StoreDirectoryService` with pure testable filters + Firebase I/O, and a `StoresScreen` that lists approved stores, lets the owner submit/edit their own (pending admin approval), lets the admin approve/delete, and opens a store in a `WebViewWidget` (external tab on web). The bottom-bar «التقارير» item (index 3) becomes «المشتريات»; Reports stay reachable from the drawer.

**Tech Stack:** Flutter, `firebase_database`, `firebase_auth`, `webview_flutter` (all already dependencies), Node for the emulator rules test.

**Spec:** `docs/superpowers/specs/2026-11-12-agent-stores-purchases-design.md`

## Global Constraints

- RTDB keys cannot contain `. # $ [ ] /` — use Firebase push ids for `stores/{key}`.
- Store records hold **public info only** — never a password, token, uid-secret, username, or the user's email.
- Admin uid is `wE10WciDVudIOJziBurjhBxpDfO2`. Agent role lives at `agents/{uid}/profile/role === 'agent'`; owner display name at `agents/{uid}/profile/name`.
- `approved` starts `false` and may be set `true` **only by the admin** (enforced in rules).
- Do not deploy rules in this plan. Rules land in `database.rules.json` + pass the emulator test; actual `firebase deploy --only database` is a separate step gated on explicit user approval per [[netagent-firebase-rules]] (live-compare → backup → emulator → deploy).
- On web (`kIsWeb`) open store URLs in an external tab via `url_launcher`; `webview_flutter` is mobile-only.
- Store `url` must start with `https://`.

## Review Focus

- **Blank/whitespace store name or URL submitted** → `submit` must reject before writing (owner sees a validation error, no empty record). Covered in Task 1 `validateSubmission` tests.
- **Non-https or malformed URL** (`http://`, `ftp://`, `javascript:`, bare host) → rejected client-side and by rules. Covered in Task 1 (`validateSubmission`) + Task 2 (rules `url` validate).
- **Agent tries to self-approve** (writes `approved:true` on their own store) → rules deny. Covered in Task 2.
- **Agent tries to write/delete another agent's store** → rules deny (ownerUid mismatch). Covered in Task 2.
- **A pending (unapproved) store leaking to other agents** → `visibleFor` must return a non-owner's pending store to the admin only, never to other agents. Covered in Task 1 `visibleFor` tests.

---

### Task 1: Store model + `StoreDirectoryService`

**Files:**
- Create: `lib/services/store_directory_service.dart`
- Test: `test/store_directory_service_test.dart`

**Interfaces:**
- Consumes: nothing (new leaf service).
- Produces:
  - `class Store` — fields `key`(String), `name`(String), `url`(String), `logoUrl`(String, default ''), `whatsapp`(String, default ''), `description`(String, default ''), `ownerUid`(String), `ownerName`(String), `approved`(bool), `updatedAt`(int). Getter `String get logo` = `logoUrl` if non-empty else `https://www.google.com/s2/favicons?domain=<host-of-url>&sz=64`. `static Store? fromSnapshot(String key, Object? value)` (returns null if name/url/ownerUid missing).
  - `class StoreSubmission` — `name, url, logoUrl?, whatsapp?, description?` (trimmed).
  - `static String? validateSubmission(StoreSubmission s)` — returns an Arabic error message or null if valid. Pure.
  - `static List<Store> visibleFor({required List<Store> all, required String uid, required bool isAdmin})` — admin: all, sorted by name; agent: approved stores **plus** own pending, sorted by name. Pure.
  - `Future<List<Store>> load()`, `Future<void> submit(StoreSubmission s, {required String ownerUid, required String ownerName})`, `Future<void> updateOwn(String key, StoreSubmission s)`, `Future<void> deleteOwn(String key)`, `Future<void> approve(String key)`, `Future<void> deleteAny(String key)`.

- [ ] **Step 1: Write failing tests** in `test/store_directory_service_test.dart`:

```dart
group('Store.fromSnapshot', () {
  test('parses a full record', () {
    final s = Store.fromSnapshot('k1', {
      'name': 'شمس', 'url': 'https://shams-ftth.vercel.app',
      'ownerUid': 'u1', 'ownerName': 'مكتب شمس', 'approved': true, 'updatedAt': 5,
    });
    expect(s, isNotNull);
    expect(s!.name, 'شمس');
    expect(s.approved, isTrue);
  });
  test('returns null when name or url missing', () {
    expect(Store.fromSnapshot('k', {'url': 'https://x.com', 'ownerUid': 'u'}), isNull);
    expect(Store.fromSnapshot('k', {'name': 'x', 'ownerUid': 'u'}), isNull);
  });
  test('logo falls back to favicon of the url host', () {
    final s = Store.fromSnapshot('k', {
      'name': 'x', 'url': 'https://shop.example.com/p', 'ownerUid': 'u', 'ownerName': 'o', 'approved': false,
    })!;
    expect(s.logo, contains('domain=shop.example.com'));
  });
});

group('validateSubmission', () {
  StoreSubmission sub({String name = 'متجر', String url = 'https://a.com', String logo = '', String wa = '', String desc = ''}) =>
      StoreSubmission(name: name, url: url, logoUrl: logo, whatsapp: wa, description: desc);
  test('accepts a valid submission', () => expect(StoreDirectoryService.validateSubmission(sub()), isNull));
  test('rejects blank name', () => expect(StoreDirectoryService.validateSubmission(sub(name: '   ')), isNotNull));
  test('rejects blank url', () => expect(StoreDirectoryService.validateSubmission(sub(url: '  ')), isNotNull));
  test('rejects non-https url', () {
    expect(StoreDirectoryService.validateSubmission(sub(url: 'http://a.com')), isNotNull);
    expect(StoreDirectoryService.validateSubmission(sub(url: 'javascript:alert(1)')), isNotNull);
    expect(StoreDirectoryService.validateSubmission(sub(url: 'a.com')), isNotNull);
  });
  test('rejects name over 80 chars', () => expect(StoreDirectoryService.validateSubmission(sub(name: 'ش' * 81)), isNotNull));
});

group('visibleFor', () {
  final approved = Store(key: 'a', name: 'ألف', url: 'https://a.com', ownerUid: 'u2', ownerName: 'o2', approved: true, updatedAt: 1);
  final myPending = Store(key: 'b', name: 'باء', url: 'https://b.com', ownerUid: 'me', ownerName: 'me', approved: false, updatedAt: 1);
  final otherPending = Store(key: 'c', name: 'جيم', url: 'https://c.com', ownerUid: 'u3', ownerName: 'o3', approved: false, updatedAt: 1);
  test('agent sees approved + own pending, not others pending', () {
    final v = StoreDirectoryService.visibleFor(all: [approved, myPending, otherPending], uid: 'me', isAdmin: false);
    expect(v.map((s) => s.key), containsAll(['a', 'b']));
    expect(v.map((s) => s.key), isNot(contains('c')));
  });
  test('admin sees everything', () {
    final v = StoreDirectoryService.visibleFor(all: [approved, myPending, otherPending], uid: 'admin', isAdmin: true);
    expect(v.map((s) => s.key), containsAll(['a', 'b', 'c']));
  });
  test('result is sorted by name', () {
    final v = StoreDirectoryService.visibleFor(all: [otherPending, approved], uid: 'x', isAdmin: true);
    expect(v.first.name, 'ألف');
  });
});
```

- [ ] **Step 2: Run tests, verify they fail** — `flutter test test/store_directory_service_test.dart` → FAIL (undefined `Store` / `StoreDirectoryService`).

- [ ] **Step 3: Implement `lib/services/store_directory_service.dart`.** Model `Store`/`StoreSubmission` as above; `logo` host parsed via `Uri.tryParse(url)?.host`. `validateSubmission`: trim; name 1..80; url must `startsWith('https://')` and parse to a non-empty host; logoUrl ≤500; whatsapp ≤30; description ≤200 — Arabic messages. `visibleFor`: filter then `..sort((a,b)=>a.name.compareTo(b.name))`. Firebase methods mirror `SasDirectoryService` (guard `Firebase.apps.isNotEmpty` and `currentUser != null`, `ref('stores')`, `push()` for `submit` writing `approved:false` + `ownerUid` + `ownerName` + `ServerValue.timestamp`; `approve` sets `approved:true`; wrap in try/catch + `.timeout(8s)`).

- [ ] **Step 4: Run tests, verify they pass** — `flutter test test/store_directory_service_test.dart` → PASS.

- [ ] **Step 5: Commit** — `git add lib/services/store_directory_service.dart test/store_directory_service_test.dart && git commit -m "Add store directory service for agent stores (المشتريات)"`

---

### Task 2: Firebase `stores` rules + emulator test

**Files:**
- Modify: `database.rules.json` (add a `stores` block beside `sasDirectory`, ~line 185)
- Create: `tool/store_rules_test.mjs`

**Interfaces:**
- Consumes: the node shape written by Task 1 `submit` (`name,url,ownerUid,ownerName,approved,updatedAt`, optional `logoUrl,whatsapp,description`).
- Produces: deployed-shape rules (deploy itself is out of scope).

- [ ] **Step 1: Write the failing rules test** `tool/store_rules_test.mjs`, modeled on `tool/sas_directory_rules_test.mjs` (same token/req/check harness). Seed `agents: {a1:{profile:{role:'agent'}}, a2:{profile:{role:'agent'}}, pending:{profile:{firstName:'x'}}}`. A valid entry: `{name:'متجر', url:'https://shams-ftth.vercel.app', ownerUid:'a1', ownerName:'مكتب', approved:false, updatedAt:1}`. Cases (expected allowed/denied):
  - agent reads stores — allowed; admin reads — allowed; non-agent reads — denied; signed-out reads — denied.
  - agent a1 writes own store (`ownerUid:a1`, `approved:false`) — allowed.
  - agent a1 writes with `approved:true` — denied.
  - agent a1 writes store with `ownerUid:a2` — denied.
  - agent a1 writes non-https url — denied.
  - agent writes name over 80 chars — denied.
  - agent writes unknown field — denied.
  - agent a2 overwrites a1's store — denied; a1 deletes own — allowed.
  - admin sets `approved:true` on a1's store — allowed; admin deletes any — allowed.

- [ ] **Step 2: Run it, verify it fails** — start emulator (`java -jar ~/.cache/firebase/emulators/firebase-database-emulator-v4.11.2.jar --port 9123`), `node tool/store_rules_test.mjs database.rules.json` → several FAIL (no `stores` rules yet; writes/reads fall through to defaults).

- [ ] **Step 3: Add the `stores` block to `database.rules.json`.** `.read`: admin OR agent-role. `stores/$key`: `.write` = admin (full) OR (agent-role AND on create/update `newData.child('ownerUid').val() === auth.uid` AND on delete `data.child('ownerUid').val() === auth.uid`). `.validate` = `!newData.exists() || newData.hasChildren(['name','url','ownerUid','ownerName','approved'])`. Child validates: `name` string 1..80; `url` string 1..300 AND `newData.val().startsWith('https://')` (use `.matches(/^https:\/\//)`); `ownerUid`/`ownerName` string; `logoUrl` string ≤500; `whatsapp` string ≤30; `description` string ≤200; `approved` boolean AND (`newData.val() === false || auth.uid === 'wE10WciDVudIOJziBurjhBxpDfO2'`); `updatedAt` number; `$other` → validate false.

- [ ] **Step 4: Run it, verify it passes** — `node tool/store_rules_test.mjs database.rules.json` → ALL PASSED. Also re-run `node tool/sas_directory_rules_test.mjs database.rules.json` to confirm no regression.

- [ ] **Step 5: Commit** — `git add database.rules.json tool/store_rules_test.mjs && git commit -m "Add stores Firebase rules + emulator test (المشتريات)"` (no deploy — deploy is a separate approved step).

---

### Task 3: «المشتريات» UI + bottom-bar swap

**Files:**
- Create: `lib/screens/stores_screen.dart` (holds `StoresScreen`, `StoreFormDialog`, `StoreWebViewScreen`)
- Modify: `lib/screens/dashboard_widgets.dart:411` (bottom-bar item 3)
- Modify: `lib/screens/dashboard_screen.dart:2112-2113` (`_onBottomNavigation` case 3)
- Modify: `lib/screens/subscribers_screen.dart:3038-3042` (`_onBottomNavigation` case 3)
- Test: `test/stores_screen_test.dart`

**Interfaces:**
- Consumes: `StoreDirectoryService`, `Store`, `StoreSubmission`, `visibleFor` from Task 1.
- Produces: `StoresScreen` (const constructor) opened from both nav handlers at index 3.

- [ ] **Step 1: Write a failing widget test** `test/stores_screen_test.dart`: pump `StoresScreen` with an injected list (add a `@visibleForTesting StoresScreen.withStores(List<Store> stores)` constructor, or an optional `List<Store>? initialStores` param that skips the Firebase load). Assert: an approved store's name renders; the owner's own pending store shows a «قيد المراجعة» label; tapping «أضف متجري» opens `StoreFormDialog` and a blank name shows the validation error (no write). Keep it light — one `testWidgets` with 2–3 `expect`s.

- [ ] **Step 2: Run it, verify it fails** — `flutter test test/stores_screen_test.dart` → FAIL (undefined `StoresScreen`).

- [ ] **Step 3: Implement `lib/screens/stores_screen.dart`.**
  - `StoresScreen`: loads via `StoreDirectoryService().load()` in `initState` (unless `initialStores` injected), computes `visibleFor` with current uid + `isAdmin` (uid == admin const), renders a searchable list (logo via `Image.network(store.logo)` with error fallback icon, name, ownerName, description). Owner's pending store carries a «قيد المراجعة» chip + edit/delete. Admin sees a «قيد المراجعة» section with approve/delete buttons. Tapping an approved store → `StoreWebViewScreen(url: store.url)`. A «أضف متجري» FAB/button → `StoreFormDialog`.
  - `StoreFormDialog`: fields name/url/logo?/whatsapp?/description?; on submit calls `validateSubmission`, shows the returned Arabic error inline if any, else `submit(...)` and a «بانتظار موافقة الإدارة» snackbar.
  - `StoreWebViewScreen`: on `kIsWeb` → `launchUrl(Uri.parse(url), mode: externalApplication)` and a simple "افتح في المتصفح" placeholder; else `WebViewController..loadRequest(Uri.parse(url))` in a `WebViewWidget` with a loading indicator and a refresh/open-in-browser action. Follow `ftth_payment_screen.dart` for the controller setup.

- [ ] **Step 4: Swap the bottom bar + nav.**
  - `dashboard_widgets.dart:411`: `(Icons.bar_chart_rounded, 'التقارير')` → `(Icons.storefront_rounded, 'المشتريات')`.
  - `dashboard_screen.dart`: add `import 'stores_screen.dart';`; `case 3: _pushDashboard(const StoresScreen());`.
  - `subscribers_screen.dart`: add the import; `case 3:` push `const StoresScreen()`.
  - (Reports stay reachable — the drawer «تقارير سريعة»/«التقارير الحسابية» items are untouched.)

- [ ] **Step 5: Run tests, verify they pass** — `flutter test test/stores_screen_test.dart` → PASS. Then `flutter analyze lib/screens/stores_screen.dart lib/screens/dashboard_widgets.dart` → no new errors.

- [ ] **Step 6: Commit** — `git add lib/screens/stores_screen.dart lib/screens/dashboard_widgets.dart lib/screens/dashboard_screen.dart lib/screens/subscribers_screen.dart test/stores_screen_test.dart && git commit -m "Add المشتريات stores screen + swap it into the bottom bar"`

---

### Task 4: Full suite + bump

**Files:**
- Modify: `pubspec.yaml` (version bump when releasing — only when the user asks to build)

- [ ] **Step 1: Run the full suite** — `flutter test` → all pass (existing + new). Fix any regression before proceeding.
- [ ] **Step 2: STOP for rules deploy + release.** Do **not** deploy rules or build without explicit user approval. When the user asks: follow [[netagent-firebase-rules]] to deploy the `stores` block, bump `pubspec.yaml`, build the AAB, and hand the path over per [[netagent-play-release]] / [[netagent-batch-releases]].
