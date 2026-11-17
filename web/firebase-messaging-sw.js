/* إشعارات وكيل نت على الويب (Firebase Cloud Messaging).
 * يعرض الإشعار والصفحة مغلقة أو في الخلفية، ويفتح التطبيق عند الضغط عليه.
 * الإعدادات أدناه عامة (هي نفسها في lib/firebase_options.dart)، وليست أسراراً.
 * نسخة SDK = supportedFirebaseJsSdkVersion في firebase_core_web المقفلة. */

// قبل تحميل Firebase: معالج Firebase للضغط يوقف المعالجات التي بعده.
self.addEventListener('notificationclick', (event) => {
  const message = event.notification && event.notification.data && event.notification.data.FCM_MSG;
  const kind = (message && message.data && message.data.kind) || '';
  event.notification.close();
  event.stopImmediatePropagation();
  const target = new URL(kind ? `/?push=${encodeURIComponent(kind)}` : '/', self.location.origin).href;
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windows) => {
      for (const client of windows) {
        if (new URL(client.url).origin === self.location.origin && 'focus' in client) {
          return client.focus();
        }
      }
      return self.clients.openWindow(target);
    }),
  );
});

importScripts('https://www.gstatic.com/firebasejs/12.19.0/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/12.19.0/firebase-messaging-compat.js');

firebase.initializeApp({
  apiKey: 'AIzaSyBMcV1XkILsjalRqZtJl7xAuUu3yJd2u30',
  appId: '1:297741444994:web:d73cfd79b421f24bc0919b',
  messagingSenderId: '297741444994',
  projectId: 'wakeiq-4b97b',
  authDomain: 'wakeiq-4b97b.firebaseapp.com',
  storageBucket: 'wakeiq-4b97b.firebasestorage.app',
});

// الإشعارات التي تحمل notification تُعرض تلقائياً حين لا تكون الصفحة ظاهرة.
firebase.messaging();
