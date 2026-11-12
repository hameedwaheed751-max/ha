# أجهزة المتجر (Store Device Listings) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans / subagent-driven-development. Steps use `- [ ]`.

**Goal:** Approved agents list devices for sale (images + description + title + price + WhatsApp) inside their store in المشتريات; other agents browse a store's devices and open each device's detail.

**Architecture:** Reuse the stores pattern. `stores.url` becomes optional (store = device container). New RTDB node `products/{id}` owner-locked like `stores`, no per-product approval (inherits store approval). Images go to Firebase Storage via the existing `putData(readAsBytes)` pattern (`payment_request_service.uploadReceiptImage`), stored as download URLs. Tapping a store opens `StoreDetailScreen` (device grid) → `ProductDetailScreen`.

**Tech Stack:** Flutter, firebase_database, firebase_storage, image_picker, url_launcher (WhatsApp), all existing deps.

**Spec:** `docs/superpowers/specs/2026-11-12-store-device-listings-design.md`

## Global Constraints

- Admin uid `wE10WciDVudIOJziBurjhBxpDfO2`; agent role at `agents/{uid}/profile/role === 'agent'`.
- Products hold public info only. Owner-locked writes (check both existing and new ownerUid). No per-product approval.
- **Storage rules unchanged** — product images upload under `product_images/{uid}/{productKey}/...` using the same authenticated access receipts/chat already use. (No `firebase.storage` rules release exists; do not create/deploy one in this plan — it risks the working receipt/chat uploads. If live uploads are denied, add owner-scoped Storage rules as a separate gated step.)
- RTDB `products` rules deploy is a separate gated step per [[netagent-firebase-rules]] (live-compare → backup → emulator → deploy).
- Images ≤5 per product, ≤~3MB each; price ≥0.
- WhatsApp opens `wa.me`. iframe/WebView https only (reuse existing StoreWebViewScreen for the optional site).

## Review Focus

- **Product with no images** → `validateSubmission` rejects before any Storage upload or DB write. (Task 2)
- **Blank/overlong description** (empty or >500) → rejected. (Task 2 + rules Task 1)
- **Agent writes another agent's product** (ownerUid mismatch) → rules deny. (Task 1)
- **>5 images** submitted → client caps at 5 and rules reject index ≥5. (Task 1 + Task 2)
- **Store with no website url** → still valid (url optional); store card/detail must not assume a url. (Task 3 + rules Task 1)

---

### Task 1: `products` rules + stores.url optional + emulator test

**Files:** Modify `database.rules.json`; Create `tool/product_rules_test.mjs`.

- [ ] **Step 1: Write `tool/product_rules_test.mjs`** (harness copied from `store_rules_test.mjs`). Seed agents a1,a2,pending. Valid product: `{storeKey:'s1', ownerUid:'a1', ownerName:'مكتب', description:'راوتر', images:{'0':'https://x/a.jpg'}, updatedAt:1}`. Cases: agent/admin read allowed, non-agent/signed-out denied; a1 writes own product allowed; a1 writes ownerUid:a2 denied; missing description denied; empty images denied; non-https image denied; 6th image (index '5') denied; description >500 denied; unknown field denied; a2 overwrites a1 product denied; a1 deletes own allowed; admin deletes any allowed. Also a **stores** case: agent writes a store WITHOUT url is now allowed.
- [ ] **Step 2: Run it → FAIL** (no products rules; stores still require url).
- [ ] **Step 3: Edit `database.rules.json`:**
  - `stores/$key/.validate`: drop `url` from required → `hasChildren(['name','ownerUid','ownerName','approved'])` (url child validate stays, applies only when present).
  - Add `products` block: `.read` admin or agent-role. `products/$key`: `.write` = admin OR (agent-role AND `(!data.exists()||data.child('ownerUid').val()===auth.uid)` AND `(!newData.exists()||newData.child('ownerUid').val()===auth.uid)`). `.validate` = `!newData.exists() || newData.hasChildren(['storeKey','ownerUid','ownerName','description','images'])`. Children: `storeKey`/`ownerUid` string 1..128; `ownerName` string ≤80; `description` string 1..500; `title` string ≤80; `price` number≥0; `currency` string ≤8; `whatsapp` string ≤30; `images` with `$i` validate `$i.matches(/^[0-4]$/) && newData.isString() && newData.val().length<=500 && newData.val().matches(/^https:[/][/].*/)` and images `.validate` `newData.hasChildren(['0'])`; `updatedAt` number; `$other` validate false.
- [ ] **Step 4: Run both rules tests → PASS** (`product_rules_test.mjs` all; re-run `store_rules_test.mjs` + `sas_directory_rules_test.mjs` for no regression).
- [ ] **Step 5: Commit** (no deploy).

---

### Task 2: `product_service.dart` + unit tests

**Files:** Create `lib/services/product_service.dart`, `test/product_service_test.dart`.

**Produces:**
- `class Product` {key, storeKey, ownerUid, ownerName, description, title, price(double?), currency, whatsapp, images(List<String>), updatedAt}; `firstImage` getter; `static Product? fromSnapshot(key, value)` (null if description/images empty); parse `images` from Map or List.
- `class ProductSubmission` {storeKey, description, title, price, currency, whatsapp, imageUrls(List<String>)} (trimmed).
- `static String? validateSubmission(ProductSubmission)` pure: description 1..500, at least 1 image, ≤5 images, title ≤80, price null or ≥0, whatsapp ≤30. Arabic messages.
- I/O: `Future<List<Product>> loadForStore(String storeKey)`; `Future<String?> uploadImage(XFile, {required String productKey})` (Storage `product_images/{uid}/{productKey}/{name}`, contentType by ext, returns download URL — mirrors `uploadReceiptImage`); `Future<void> add(ProductSubmission, {ownerUid, ownerName})` (push); `updateOwn(key, ...)`; `deleteOwn(key)`; `deleteAny(key)` (admin).

- [ ] **Step 1: Write failing tests** `test/product_service_test.dart`: `fromSnapshot` parses images from a `{'0':url,'1':url}` map and returns null when images missing; `validateSubmission` accepts valid, rejects empty description, rejects no images, rejects 6 images, rejects negative price, rejects description >500.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement `product_service.dart`** (upload mirrors `payment_request_service.uploadReceiptImage`; guards `Firebase.apps.isNotEmpty` + `currentUser`).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit.**

---

### Task 3: UI — store detail, product detail, product form, store url optional

**Files:** Create `lib/screens/store_detail_screen.dart` (StoreDetailScreen, ProductDetailScreen, ProductFormScreen); Modify `lib/screens/stores_screen.dart` (`_open` → push StoreDetailScreen; StoreFormDialog url optional label + allow empty); Modify `lib/services/store_directory_service.dart` (`validateSubmission`: url optional — validate https only if non-empty; set `url` '' allowed); Test `test/product_form_test.dart`.

**Consumes:** Product/ProductService (Task 2), existing `buildStoreLogo`, `StoreWebViewScreen`.

- [ ] **Step 1: Failing widget test** `test/product_form_test.dart`: pump `ProductFormScreen` (inject no Firebase), enter blank description + no image, tap save → validation error shown, no submit. Also assert `StoreDirectoryService.validateSubmission` accepts a store with empty url.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement:**
  - `store_directory_service.validateSubmission`: url optional — if `url` non-empty must be https + host; empty url allowed. (Update `submit`/`updateOwn` to write url only when non-empty.)
  - `StoresScreen._open(store)` → `Navigator.push(StoreDetailScreen(store))` instead of `StoreWebViewScreen`.
  - `StoreFormDialog`: url field label «رابط الموقع (اختياري)»; no longer required.
  - `StoreDetailScreen`: header (logo/name/owner; «زيارة الموقع» button → `StoreWebViewScreen` only if `store.url` non-empty); device grid (`buildStoreLogo`-style: `firstImage` via `buildStoreLogo`/Image; title; price). Owner/admin: «أضف جهازاً» → `ProductFormScreen`; edit/delete own. Tap device → `ProductDetailScreen`.
  - `ProductDetailScreen`: image gallery (PageView), title, price, description, WhatsApp button (`wa.me/<number>`), owner/admin edit/delete.
  - `ProductFormScreen`: `image_picker` pickMultiImage (cap 5), preview thumbs, description/title/price/currency/whatsapp fields, `validateSubmission`, upload images then `add`/`updateOwn`.
- [ ] **Step 4: Run → PASS.** Then `flutter analyze` the new/changed files.
- [ ] **Step 5: Commit.**

---

### Task 4: Full suite + gated deploy/release

- [ ] **Step 1: `flutter test` all pass.**
- [ ] **Step 2: STOP.** Push to master, deploy `products` RTDB rules, and build — each only on explicit user approval. Storage rules untouched unless live uploads prove denied.
