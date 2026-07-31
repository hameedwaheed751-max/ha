NetAgent Web Proxy v107

1) يجب تثبيت Node.js مرة واحدة.
2) شغل الملف: تشغيل_البروكسي.bat
3) اترك النافذة مفتوحة.
4) من Terminal مشروع Flutter شغل:
   flutter run -d chrome

مهم:
- التطوير المحلي اختياري فقط، ويستخدم localhost للتجربة السريعة.
- الإنتاج يجب أن يستخدم بروكسي Render عبر HTTPS فقط.
- التطبيق يقرأ رابط البروكسي من SAS_WEB_PROXY_URL أو من إعدادات التطبيق.

---

نشر دائم مجاني (بدون فتح بروكسي محلي كل مرة) عبر Render:

1) ارفع المشروع على GitHub.
2) في Render: New > Web Service.
3) اختَر المستودع وحدد Root Directory = web_proxy
4) Build Command: npm install
5) Start Command: npm start
6) بعد النشر خذ رابط الخدمة (مثال: https://your-proxy.onrender.com)

بناء Flutter Web للإنتاج مع رابط البروكسي الدائم:

flutter build web --release --dart-define=SAS_WEB_PROXY_URL=https://your-proxy.onrender.com

ملاحظة:
- لا تعتمد على localhost في الإنتاج.
- في الإنتاج يجب تمرير SAS_WEB_PROXY_URL كما في الأمر أعلاه.

---

نسخة Cloudflare Worker للبروكسي فقط:

1) ارفع الملفات على Cloudflare Workers.
2) استخدم الملف: cloudflare-worker.js
3) إذا تريد نشره بـ Wrangler محلياً:
   wrangler deploy
4) اربط الدومين أو خذ رابط worker ثم استعمله كـ SAS_WEB_PROXY_URL.

مهم:
- Cloudflare Workers لا يتجاوز مشاكل شهادة TLS المكسورة بنفس طريقة Node.
- إذا كان SAS الأصلي عنده شهادة غير صالحة، قد يفشل الطلب من Cloudflare.
