@echo off
chcp 65001 >nul
title NetAgent Web 109
cd /d "%~dp0"

where flutter >nul 2>nul
if errorlevel 1 (
  echo Flutter غير موجود في PATH
  pause
  exit /b 1
)

if "%SAS_WEB_PROXY_URL%"=="" (
  echo يجب تحديد رابط بروكسي Render عبر متغير البيئة SAS_WEB_PROXY_URL
  echo مثال:
  echo set SAS_WEB_PROXY_URL=https://your-netagent-proxy.onrender.com
  pause
  exit /b 1
)

echo تشغيل NetAgent على Chrome باستخدام بروكسي Render: %SAS_WEB_PROXY_URL%
flutter run -d chrome --dart-define=SAS_WEB_PROXY_URL=%SAS_WEB_PROXY_URL% --dart-define=SAS_USE_PROXY=true

pause
