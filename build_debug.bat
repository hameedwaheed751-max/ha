@echo off
setlocal enabledelayedexpansion

set JAVA_HOME=C:\Program Files\Android\Android Studio\jbr
echo [*] JAVA_HOME set to: %JAVA_HOME%

cd /d C:\untitled
echo [*] Current directory: %cd%

echo [*] Starting Flutter build...
call flutter build apk --debug

if %errorlevel% equ 0 (
    echo.
    echo [✓] Build completed successfully
    if exist "build\app\outputs\flutter-apk\app-debug.apk" (
        echo [✓] APK file found at: build\app\outputs\flutter-apk\app-debug.apk
    )
) else (
    echo.
    echo [✗] Build failed with error code: %errorlevel%
)

pause
