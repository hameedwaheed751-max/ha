#!/usr/bin/env pwsh

# Set Java Home for Gradle
$env:JAVA_HOME = "C:\Program Files\Android\Android Studio\jbr"

# Navigate to android directory and run build
Set-Location "$PSScriptRoot\android"

Write-Host "Building APK with Flutter..." -ForegroundColor Green
Write-Host "Java Home: $env:JAVA_HOME" -ForegroundColor Yellow

# Run gradle build
.\gradlew.bat assembleDebug --stacktrace

if ($LASTEXITCODE -eq 0) {
    Write-Host "`nBuild completed successfully!" -ForegroundColor Green
    Write-Host "APK location: $PSScriptRoot\build\app\outputs\flutter-apk\app-debug.apk" -ForegroundColor Cyan
} else {
    Write-Host "`nBuild failed with exit code: $LASTEXITCODE" -ForegroundColor Red
}
