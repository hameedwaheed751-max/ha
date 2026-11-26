# Settlement Fix & Menu Consolidation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** إصلاح «تُسجَّل عملية التسديد والدين يبقى في العمود» وتوحيد قوائم التسديد/التعديل المكرّرة، دون تغيير النموذج المالي.

**Architecture:** توجيه كل مسارات التسديد إلى دالة واحدة (`recordPartialPayment`) التي تخفض `remaining` (المرحّل + الحالي) عبر `applyPayment`؛ تحويل شاشة «ديون» إلى تعديل مبلغ الاشتراك فقط؛ منع حارس الشهر من إسقاط الحفظ؛ وإظهار فشل كتابة السجل بدل ابتلاعه.

**Tech Stack:** Flutter/Dart، flutter_test، نموذج `Subscriber`/`AppStore` القائم، Firebase RTDB (`SubscriberFinancialLedger`).

**Spec:** `docs/superpowers/specs/2026-11-26-unified-ledger-and-net-profit-design.md` (الجزء ب مُسقَط — شاشة الربح موجودة في `accounting_reports_screen.dart`).

## Global Constraints
- لا تغيير على النموذج المالي (`price`/`paid`/`carriedDebt`/`remaining`) ولا على منطق التفعيل/الربح.
- مصطلحات المستخدم في الواجهة: «تسديد»، «تعديل مبلغ الاشتراك».
- التسجيل موثوق offline: الحركة تُحفظ محلياً أولاً؛ فشل Firebase يُنبَّه لا يُبتلع.
- ردود الحالة بالعربية.

## Review Focus
- **تسديد دين مرحّل:** مشترك رصيده كله `carriedDebt` — التسديد يجب أن يخفض العمود (Task 1).
- **تغيّر الشهر أثناء التسديد:** العملية تُحفظ ولا تُسقَط ولا تُسجَّل مرتين (Task 2).
- **فشل كتابة السجل (أوفلاين/صلاحية):** الحفظ المحلي ينجح ويظهر تحذير، لا ابتلاع صامت (Task 3).
- **دفعة تفوق المتبقي:** تُحسَم عند `remaining` لا أكثر (Task 1، اختبار موجود يُحافَظ عليه).
- **ازدواج المدخلات:** لا يبقى مسار تسديد ثانٍ يعدّل المال بسلوك مختلف (Task 1).

---

### Task 1: توحيد التسديد في مسار واحد وتحويل «ديون» لتعديل السعر فقط

**Files:**
- Modify: `lib/screens/subscribers_screen.dart` — مواضع استدعاء `_debt` وتعريف `_debt` (~2682)، وربط `SubscriberDetailsScreen` (3705-3716, 3864-3876).
- Modify: `lib/screens/partial_payment_flow.dart` — `recordPartialPayment` (مسار التسديد الموحّد، قائم).
- Test: `test/debt_payment_logic_test.dart` (تمديد)، `test/subscribers_list_test.dart` (ربط القوائم).

**Interfaces:**
- Consumes: `recordPartialPayment(BuildContext, Subscriber)` — [partial_payment_flow.dart:31](../../../lib/screens/partial_payment_flow.dart#L31)؛ `Subscriber.applyPayment` (يخصم المرحّل أولاً).
- Produces: `_debt(Subscriber)` يصبح تعديل مبلغ الاشتراك فقط (لا يُحرّك دفعات)؛ كل مُشغّلات «تسديد/ديون» تصل إلى `recordPartialPayment`.

- [ ] **Step 1: اختبار نموذجي فاشل — تسديد دين مرحّل يخفض المتبقي**
```dart
test('settling carried debt reduces remaining', () {
  final s = Subscriber(user:'u', name:'n', phone:'', address:'', ip:'',
    type:'b', price:35000, paid:35000, carriedDebt:10000,
    startDate: DateTime(2026,11,1), endDate: DateTime(2026,12,1));
  expect(s.remaining, 45000);
  final applied = s.applyPartialPayment(10000, at: DateTime(2026,11,26));
  expect(applied, 10000);
  expect(s.carriedDebt, 0);
  expect(s.remaining, 35000);
});
```
- [ ] **Step 2: تشغيل الاختبار للتأكد من سلوك النموذج** — `flutter test test/debt_payment_logic_test.dart` — متوقع: ينجح (النموذج سليم؛ هذا حارس انحدار يثبّت أن المسار الصحيح هو `applyPayment`).
- [ ] **Step 3: تحويل `_debt` إلى تعديل مبلغ الاشتراك فقط** — إزالة حقل «واصل الشهر الحالي» ومنطق `adjustDebtAmounts` من [subscribers_screen.dart:2682](../../../lib/screens/subscribers_screen.dart#L2682)، وإبقاء تعديل `price` فقط مع تسجيل حدث تعديل السعر والسجل (`FinancialTransactionType.debt/adjustment`). العنوان يصبح «تعديل مبلغ الاشتراك».
- [ ] **Step 4: توجيه كل مُشغّلات التسديد إلى `recordPartialPayment`** — في `SubscriberDetailsScreen` اجعل `onEditDebt`/`onAddDebtAmount` و«ديون» في قائمة العمليات تفتح `recordPartialPayment` عند وجود `remaining`؛ مدخل «تعديل مبلغ الاشتراك» يبقى عبر `_debt`.
- [ ] **Step 5: اختبار واجهة — فتح قائمة الديون يصل لحوار التسديد** — في `test/subscribers_list_test.dart` اختبار يضغط مُشغّل «تسديد» ويتحقق من ظهور حوار «تسديد جزئي» وأن تأكيده يخفض `remaining`.
- [ ] **Step 6: تشغيل الاختبارات** — `flutter test test/debt_payment_logic_test.dart test/subscribers_list_test.dart` — متوقع: PASS.
- [ ] **Step 7: Commit** — `git add -A && git commit -m "تسديد: مسار واحد لكل القوائم + «ديون» لتعديل السعر فقط"`

### Task 2: حارس الشهر لا يُسقِط الحفظ

**Files:**
- Modify: `lib/screens/subscribers_screen.dart:2779` (حارس «بدأ شهر جديد أثناء التعديل»).
- Test: `test/debt_payment_logic_test.dart`.

**Interfaces:**
- Consumes: `Subscriber.rolloverToMonth(DateTime)` (يرجع true عند الترحيل)؛ `AppStore.rolloverMonthlyBalances()`.
- Produces: تعديل مبلغ الاشتراك يُطبَّق بعد ترحيل الشهر بدل إجهاضه.

- [ ] **Step 1: اختبار فاشل — الترحيل قبل التعديل لا يُلغي التطبيق**
```dart
test('rollover before subscription edit still applies', () {
  final s = Subscriber(user:'u', name:'n', phone:'', address:'', ip:'',
    type:'b', price:30000, paid:0,
    startDate: DateTime(2026,10,1), endDate: DateTime(2026,10,28));
  s.billingMonthKey = '2026-10';
  s.rolloverToMonth(DateTime(2026,11,26)); // ينقل 30000 إلى المرحّل
  expect(s.carriedDebt, 30000);
  final adj = s.adjustDebtAmounts(subscriptionAmount: 40000, paidAmount: 0, at: DateTime(2026,11,26));
  expect(adj.subscriptionDelta, 40000); // السعر الجديد للشهر الجديد
});
```
- [ ] **Step 2: تشغيل الاختبار** — متوقع: PASS (يوثّق السلوك المطلوب بعد الترحيل).
- [ ] **Step 3: استبدال الإجهاض بترحيل-ثم-إكمال** — في [subscribers_screen.dart:2779](../../../lib/screens/subscribers_screen.dart#L2779): بدل `return` عند اختلاف `billingMonthKey`، شغّل `AppStore.rolloverMonthlyBalances()` + `s.rolloverToMonth(now)`، حدّث `dialogBillingMonthKey`، وأكمل الحفظ. لا تسجيل مزدوج (حدث واحد للعملية).
- [ ] **Step 4: تشغيل الاختبارات** — `flutter test test/debt_payment_logic_test.dart test/daily_summary_cases_test.dart` — متوقع: PASS.
- [ ] **Step 5: Commit** — `git commit -am "تعديل السعر: ترحيل الشهر ثم الإكمال بدل إسقاط الحفظ"`

### Task 3: فشل كتابة السجل المالي يُنبَّه لا يُبتلع

**Files:**
- Modify: `lib/models.dart` (إضافة علم `AppStore.lastLedgerSyncError` بجوار `lastSaveSyncError`).
- Modify: `lib/screens/partial_payment_flow.dart:147-158` و`lib/screens/subscribers_screen.dart:540-552` (ضبط العلم عند الفشل بدل `debugPrint` فقط).
- Test: `test/finance_ledger_test.dart`.

**Interfaces:**
- Consumes: `SubscriberFinancialLedger().addTransaction(...)` (قد يرمي).
- Produces: `AppStore.lastLedgerSyncError` (String?، يُضبط عند فشل الكتابة، يُمسح عند النجاح)؛ تحذير في سناك-بار التسديد.

- [ ] **Step 1: اختبار فاشل — العلم يُضبط عند فشل الكتابة** — في `test/finance_ledger_test.dart` اختبار يستدعي الغلاف الجديد `AppStore.recordLedgerSafe(() async => throw ...)` ويتحقق `AppStore.lastLedgerSyncError != null`، ويُمسح عند نجاح استدعاء لاحق.
- [ ] **Step 2: تشغيل الاختبار** — متوقع: FAIL (الغلاف/العلم غير موجود).
- [ ] **Step 3: إضافة `AppStore.lastLedgerSyncError` والغلاف `recordLedgerSafe`** — يلتقط الاستثناء، يضبط العلم، يرجع bool؛ ويُستبدل به `try/catch` الصامت في مساري التسديد والتعديل، مع إظهار «حُفظ محلياً وتعذّر تسجيل السجل» في السناك-بار.
- [ ] **Step 4: تشغيل الاختبارات** — `flutter test test/finance_ledger_test.dart` — متوقع: PASS.
- [ ] **Step 5: Commit** — `git commit -am "السجل المالي: إظهار فشل الكتابة بدل ابتلاعه"`
