# خطة تنفيذ: تخزين صور الأجهزة على الـ VPS

> **للمنفّذ:** تُنفَّذ مهمة‑مهمة بـ TDD. الاختبار أولاً، ثم الكود، ثم تشغيل الاختبارات.

**الهدف:** نقل تخزين صور «المشتريات» إلى الـ gateway على الـ VPS عبر `/api/images`.

**المعمار:** نقاط رفع/حذف مصادَقة على الـ gateway (بلا تبعيّة جديدة، `express.raw`)،
خدمة ثابتة `/uploads`، وتبديل باطن `ProductService.uploadImage/deleteImage` في التطبيق.

**المواصفة:** `docs/superpowers/specs/2026-11-12-product-images-on-vps-design.md`

## قيود عامة
- مصادقة Firebase إلزامية؛ الهوية من التوكن؛ صلاحية الحذف للمالك/المدير خادمياً.
- Magic bytes؛ حدّ حجم؛ Rate limiting؛ منع Path traversal.
- لا تبعيّات جديدة؛ لا تغيير على Caddy/WAHA؛ لا لمس قواعد Firebase Storage.
- لا يُنفَّذ شيء على الـ VPS من Claude؛ النشر بيد المستخدم.

## مراجعة التركيز
- امتداد مخادع ← فحص الـ magic bytes (Task 1).
- رفع/حذف لوكيل آخر ← هوية من التوكن + فحص `:uid` (Task 1).
- Path traversal ← تعقيم + تحقّق جذر + أسماء عشوائية (Task 1).
- فشل الرفع/الحذف ← null عند الرفع، أفضل‑جهد عند الحذف، لا فقدان سجل (Task 2).
- رابط Firebase قديم عند الحذف ← تجاهل مضيف أجنبي (Task 2).

---

### Task 1: نقاط الصور في الـ gateway (TDD)
**ملفات:** `whatsapp_waha/gateway/server.js`؛ اختبار `whatsapp_waha/gateway/server_images.test.js`.
- [ ] اكتب اختبارات: POST صحيح→200+url+ملف؛ نوع لا يطابق→415؛ >الحد→413؛ بلا جسم→400؛
  بلا توكن→401؛ غير وكيل→403؛ تجاهل uid العميل؛ تجاوز المعدّل→429؛ GET موجود→200،
  مفقود→404، تجاوز→لا يُخدَم؛ DELETE مالك→200+حذف؛ DELETE لوكيل آخر→403؛ `..`→400؛
  مدير يحذف→200.
- [ ] شغّلها لتفشل.
- [ ] نفّذ: `loadConfig` (uploadsDir/publicBaseUrl/maxImageBytes/rateLimit/adminUid)،
  `requireAgent`، `rateLimit`، `POST/DELETE /api/images`، `GET /uploads`، CORS DELETE،
  `mkdirSync`، فحص magic bytes.
- [ ] شغّل `node --test` (كل ملفات الـ gateway) — أخضر، وشمولاً اختبارات `/api/waha` الحالية.
- [ ] Commit.

### Task 2: رفع/حذف الصور في التطبيق (TDD)
**ملفات:** `lib/services/product_service.dart`؛ `lib/screens/store_detail_screen.dart`؛
اختبار `test/product_service_test.dart` (+حالات جديدة).
- [ ] اكتب اختبارات: `uploadImage` يستدعي uploader محقوناً ويعيد رابطه، فشل→null؛
  `deleteImage` يستدعي حذفاً لمضيف الـ gateway ويتجاهل أجنبياً؛ `updateOwn` يكتب ثم يحذف
  القديمة غير المُشار إليها؛ `_remove` يحذف السجل ثم الصور.
- [ ] شغّلها لتفشل.
- [ ] نفّذ: `ProductImageUploader` محقون + افتراضي مدعوم بالـ gateway؛ تبديل `uploadImage`؛
  `deleteImage`؛ ربط الحذف في `_remove`/`updateOwn`؛ تصغير الصور في `_pick`؛ إزالة
  استيراد `firebase_storage` إن لزم.
- [ ] شغّل `flutter test` — أخضر، والاختبارات الحالية سليمة.
- [ ] Commit.

### Task 3: الإعداد المرجعي (توثيق)
**ملفات:** `whatsapp_waha/compose.production.yaml`، `whatsapp_waha/.env.example`.
- [ ] أضف `PUBLIC_BASE_URL`/`MAX_IMAGE_BYTES`/`RATE_LIMIT_*` كاختيارية موثّقة.
- [ ] Commit.

### Task 4: فحوصات السلامة
- [ ] `flutter analyze` نظيف؛ `flutter test` كامل أخضر؛ `node --test` في الـ gateway أخضر.
- [ ] تأكيد لا تعارض مع مسارات/خدمات حالية.

### Task 5: بوابة دوام التخزين (يتوقّف — تنفيذ المستخدم)
- [ ] المستخدم يشغّل `docker inspect` للتأكد من مُركَّب `/app/data` الدائم ويبلّغ النتيجة.
- [ ] إن غاب المُركَّب: توقّف والرجوع للمستخدم (لا حل مؤقت).

### Task 6: البناء والنشر (بناء محلي ثم تنفيذ المستخدم)
- [ ] بناء صورة الـ gateway محلياً (`--platform linux/amd64`) و`docker save` إلى TAR.
- [ ] تسليم المستخدم أمري scp و`replace-gateway.sh`؛ المستخدم ينفّذهما.

### Task 7: تحقّق ما بعد النشر
- [ ] اختبار الرفع والعرض والحذف حيّاً (عبر التطبيق/موجّهاً).
- [ ] تقرير نهائي: الملفات المعدّلة، الاختبارات، نتائج النشر.
