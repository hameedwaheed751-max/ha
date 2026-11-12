# تخزين صور الأجهزة على خادم الـ VPS — مواصفة التصميم

**التاريخ:** 2026-11-12
**الحالة:** مُوافَق على التصميم (بانتظار مراجعة المواصفة)

## الهدف

نقل تخزين صور أجهزة «المشتريات» من Firebase Storage إلى خادم الـ VPS
(حاوية `netagent-gateway`): الوكيل يرفع صورة الجهاز إلى الـ gateway، فتُخزَّن
على قرص الخادم وتُقدَّم عبر رابط عام HTTPS يُحفظ كما هو في `products/.../images[]`.

## الدافع والقرار

اختار المستخدم تخزين الصور على الـ VPS بدل Firebase Storage. البنية التحتية
تسمح بذلك دون أي تغيير عليها:

- **Caddy** (`Caddyfile.production`) يمرّر *كل* المسارات إلى `gateway:3001`
  عبر `reverse_proxy` شامل، و**بلا حدٍّ افتراضي لحجم جسم الطلب** — فرفع صور
  بعدة ميغابايت يمرّ دون إعداد.
- `./gateway/data:/app/data` مُركَّب bind دائم (نفس مجلد `idempotency.json`).
  `replace-gateway.sh` ينسخ كل المجلدات عند الاستبدال، فالصور تبقى بعد النشر.
  جذر الحاوية `read_only` لكن `/app/data` قابل للكتابة.
- المصادقة (Firebase Bearer + فحص دور الوكيل) وCORS للويب جاهزة ونعيد استخدامها.

**النتيجة:** لا تغيير على Caddy، ولا مجلد جديد، ولا متغيّر بيئة إلزامي جديد.
النشر = إعادة بناء صورة الـ gateway محلياً ← TAR ← المستخدم يرفع بـ scp ويشغّل
`replace-gateway.sh` (المسار المعتاد).

## القيود العامة (Global Constraints)

- الصور تُخزَّن تحت `/app/data/uploads/<uid>/<عشوائي>.<ext>` فقط (المجلد الوحيد
  الدائم والقابل للكتابة مع جذر `read_only`).
- الرابط العام يُبنى من `PUBLIC_BASE_URL`، افتراضه `https://netagentiraq.duckdns.org`
  (قابل للتجاوز بمتغيّر بيئة، لكن **غير إلزامي** كي يبقى مسار النشر الناسخ للبيئة سليماً).
- **لا تبعيّة جديدة** في الـ gateway: الرفع عبر `express.raw` (لا multer).
- أنواع الصور المقبولة: `image/jpeg`، `image/png`، `image/webp` فقط، ويُتحقَّق
  منها بالبايتات الأولى (magic bytes)، لا بترويسة العميل وحدها.
- الحد الأقصى لحجم الصورة: `MAX_IMAGE_BYTES`، افتراضه 4 ميغابايت.
- أقصى عدد صور للجهاز يبقى 5 (`ProductService.maxImages`).
- الصور تُصغَّر في العميل قبل الرفع: `image_picker` بعرض 1600px وجودة 80.
- أسماء الملفات عشوائية؛ الامتداد يُشتَق من النوع المُتحقَّق منه، لا من اسم العميل.
- لا تُطبع أسرار/توكنات. لا يُنفَّذ شيء على الـ VPS من هنا.

## المعمار

### 1) الـ gateway (`whatsapp_waha/gateway/server.js`)

يُعاد استخدام `verifyIdToken` + `authorizeAccount` (الموجودان) في دالة مصادقة
مشتركة `requireAgent(req,res,next)` تضع `req.agentUid`.

**نقاط جديدة (قبل/بجانب كتلة `/api/waha`):**

- `POST /api/images`
  - مصادَقة عبر `requireAgent`.
  - جسم الطلب: بايتات الصورة الخام، `Content-Type` من الأنواع المقبولة،
    بحدّ `MAX_IMAGE_BYTES` عبر `express.raw({ type: [...accepted], limit })`.
  - يتحقق من الـ magic bytes ويطابقها مع `Content-Type`؛ يرفض غير ذلك بـ 415.
  - يكتب الملف إلى `<uploadsDir>/<agentUid>/<token>.<ext>` حيث `<token>`
    عشوائي (`crypto.randomBytes(16).hex`)، و`<ext>` من النوع المُتحقَّق.
  - يعيد `200 { success:true, url: "<PUBLIC_BASE_URL>/uploads/<agentUid>/<token>.<ext>" }`.
  - أخطاء: 400 جسم فارغ، 413 تجاوز الحجم، 415 نوع غير مقبول، 401/403 مصادقة،
    500 فشل كتابة.

- `DELETE /api/images/:uid/:file`
  - مصادَقة عبر `requireAgent`.
  - يسمح فقط إذا `:uid === req.agentUid` أو كان المستخدم المدير (`kAdminUid`).
  - `:file` يُتحقَّق بـ `^[A-Za-z0-9._-]{1,120}$` وبلا `..`؛ وإلا 400.
  - حذف أفضل جهد: يحذف الملف إن وُجد؛ يعيد `200 { success:true }` حتى لو كان
    مفقوداً؛ لا يكشف وجود/عدم وجود الملف.

- خدمة ثابتة عامة `GET /uploads/*`
  - `express.static(uploadsDir, { index:false, dotfiles:'deny', fallthrough:false,
    maxAge:'7d', setHeaders: ضبط Cache-Control })`.
  - `express.static` يمنع الخروج فوق الجذر (path traversal).
  - عامة بلا مصادقة (صور أجهزة غير حساسة).

**التهيئة (`loadConfig`):**
- `uploadsDir`: `UPLOADS_DIR` أو `path.join(dirname(idempotencyFile), 'uploads')`
  → `/app/data/uploads`.
- `publicBaseUrl`: `PUBLIC_BASE_URL` أو `https://netagentiraq.duckdns.org`؛
  يجب أن يبدأ `https://` وبلا `/` زائدة.
- `maxImageBytes`: `MAX_IMAGE_BYTES` أو `4*1024*1024` (ضمن حدّ معقول).
- `adminUid`: `NETAGENT_ADMIN_UID` أو الثابت `wE10WciDVudIOJziBurjhBxpDfO2`.
- عند البدء: `fs.mkdirSync(uploadsDir, { recursive:true })` (تحت `/app/data` القابل للكتابة).

**CORS:** إضافة `DELETE` إلى `Access-Control-Allow-Methods` في الوسيط الحالي
(الترويسات `Authorization, Content-Type` مسموحة أصلاً). الرفع من الويب: الأصل
موجود في `CORS_ALLOWED_ORIGINS`. عرض الصور عبر `<img>` لا يحتاج CORS.

### 2) التطبيق (`lib/services/product_service.dart`)

- `uploadImage` يتحوّل من `FirebaseStorage` إلى POST للـ gateway:
  - يجلب توكن Firebase الحالي، يرسل `http.post('<gateway>/api/images',
    headers:{Authorization:'Bearer <idToken>', 'Content-Type':<contentType>},
    body: await file.readAsBytes())`، ويقرأ `url` من الرد.
  - لإبقاء الخدمة قابلة للاختبار: حقن `ProductImageUploader`
    (دالة `Future<String?> uploadBytes(Uint8List bytes, {required String contentType})`)
    عبر المُنشئ بقيمة افتراضية مدعومة بالـ gateway (رابط افتراضي
    `https://netagentiraq.duckdns.org`، توكن من `FirebaseAuth`، نمط `WahaNotificationService`).
  - دالة حذف جديدة `deleteImage(String url)` (أفضل جهد) تُحلّل مسار
    `/uploads/<uid>/<file>` من الرابط وتستدعي `DELETE /api/images/<uid>/<file>`؛
    تُستدعى عند حذف الجهاز وعند إزالة صورة من النموذج. أي رابط ليس من مضيف الـ
    gateway (روابط Firebase قديمة) يُتجاهَل بصمت.
  - إزالة `import firebase_storage` إن لم يبقَ مستعمَلاً.

- `_remove`/`deleteOwn`/`deleteAny`: قبل حذف سجل الجهاز من RTDB، تُجمع روابط
  صوره وتُستدعى `deleteImage` لكل منها (أفضل جهد، لا يُعطّل الحذف).

### 3) الواجهة (`lib/screens/store_detail_screen.dart`)

- `ProductFormScreen._pick`: تمرير `maxWidth:1600, imageQuality:80` إلى
  `pickMultiImage` لتصغير الصور قبل الرفع.
- عند إزالة صورة محفوظة من النموذج (ضمن `_keptUrls`): تُستدعى
  `ProductService.deleteImage` (أفضل جهد) للرابط المُزال عند الحفظ فقط إن لم
  يعُد ضمن الصور النهائية.

### 4) الإعداد المرجعي (توثيق فقط، لا يغيّر الحيّ)

تحديث `whatsapp_waha/compose.production.yaml` و`.env.example` بإضافة
`PUBLIC_BASE_URL` و`MAX_IMAGE_BYTES` كمتغيّرات اختيارية موثّقة، مع ملاحظة أنّ
القيم الافتراضية في الكود تكفي للنشر الحالي.

## تدفّق البيانات

1. الوكيل يختار صورة (مصغّرة) ← التطبيق POST بايتاتها إلى `/api/images` بتوكنه.
2. الـ gateway يصادق، يتحقق، يكتب الملف، يعيد الرابط العام.
3. التطبيق يجمع الروابط في `images[]` ويكتب سجل الجهاز في RTDB (بالقواعد الحالية
   التي تقبل أي `https://`).
4. العرض: `buildStoreImageFill` يعرض الرابط عبر `<img>` (ويب) أو `Image.network` (جوال).
5. الحذف: حذف سجل الجهاز/إزالة صورة ← التطبيق `DELETE /api/images/...` (أفضل جهد).

## الأمان

- الرفع والحذف للوكلاء المصادَقين فقط؛ الحذف مقيَّد بمالك الـ `uid` أو المدير.
- `uid` عند الرفع من التوكن المُتحقَّق، لا من إدخال العميل.
- `:file` عند الحذف يُعقَّم (نمط صارم، لا `..`/`/`).
- التحقق من نوع الصورة بالـ magic bytes.
- حدّ الحجم عبر `express.raw` وبفحص صريح.
- أسماء ملفات عشوائية تقلّل التخمين/التعداد.
- الكتابة محصورة في `/app/data` (الوحيد القابل للكتابة مع `read_only`).

## الاختبار

**الـ gateway (`node --test`, على نمط `server.test.js` بحقن `verifyIdToken`/`authorizeAccount` ومجلد مؤقت):**
- POST صورة JPEG صحيحة (وكيل) → 200 + `url` + الملف مكتوب على القرص.
- POST بترويسة `Content-Type` لا تطابق البايتات → 415، لا ملف.
- POST أكبر من الحد → 413.
- POST بلا توكن → 401؛ بتوكن غير وكيل → 403.
- GET `/uploads/<file>` لملف موجود → 200 بنفس البايتات والنوع الصحيح.
- GET `/uploads/<file>` مفقود → 404.
- DELETE صورة المالك → 200 + الملف محذوف.
- DELETE بـ `:uid` لوكيل آخر (غير مدير) → 403، الملف باقٍ.
- DELETE باسم ملف فيه `..` → 400.
- المدير يحذف صورة أي وكيل → 200.

**التطبيق (`flutter test`):**
- `ProductService.uploadImage` يستدعي الـ uploader المحقون ويعيد رابطه.
- `deleteImage` يستدعي الـ uploader/الحذف لرابط من مضيف الـ gateway، ويتجاهل رابطاً أجنبياً.
- اختبارات `product_service_test`/`product_form_test`/الواجهة الحالية تبقى خضراء.

## مجال التركيز للمراجعة (Review Focus)

- **صورة بامتداد مخادع** (مثلاً `.jpg` لكن بايتات PNG): يُعتمد النوع من الـ
  magic bytes، والامتداد منه — اختبار عدم تطابق النوع يغطّيه.
- **محاولة حذف ملف وكيل آخر/خارج المجلد**: فحص `:uid` والنمط الصارم — مغطّى.
- **رفع بلا جسم أو جسم ضخم**: 400/413 — مغطّى.
- **رابط Firebase قديم عند الحذف**: `deleteImage` يتجاهل أي مضيف غير الـ gateway — مغطّى.
- **فشل الرفع (شبكة/خادم)**: `uploadImage` يعيد `null`، والنموذج يُبقي الصورة
  غير مرفوعة ويعرض خطأ بدل حفظ جهاز بصورة ناقصة — يُغطّى باختبار الواجهة/الخدمة.

## خارج النطاق

- لا هجرة لصور قديمة (الميزة شُحنت اليوم؛ الروابط القديمة تبقى تعمل).
- لا تنظيف دوري/حصص قرص (يُضاف لاحقاً إن لزم).
- قواعد Firebase Storage لا تُلمَس.
