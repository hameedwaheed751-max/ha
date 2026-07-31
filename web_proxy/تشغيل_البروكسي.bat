@echo off
chcp 65001 >nul
title NetAgent SAS Proxy
cd /d "%~dp0"
set "PORT=3000"
set "ALLOW_INSECURE_TLS=1"
set "ALLOW_PRIVATE_TARGETS=1"
echo تشغيل بروكسي SAS المحلي للتطوير فقط على http://127.0.0.1:%PORT%
echo هذا الملف مخصص للتطوير المحلي فقط، وليس للإنتاج.
echo في الإنتاج استخدم بروكسي Render عبر HTTPS فقط.
echo تم تفعيل تجاوز شهادة SAS غير الموثوقة والسماح بعناوين الشبكة المحلية.
node server.js
pause
