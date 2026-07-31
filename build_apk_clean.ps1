# Clean build script for Flutter APK
Write-Host "========================================" -ForegroundColor Green
Write-Host "Flutter APK Build Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Green

# Set Java home
$java_home = "C:\Program Files\Android\Android Studio\jbr"
[Environment]::SetEnvironmentVariable('JAVA_HOME', $java_home, 'Process')
Write-Host "[OK] JAVA_HOME set to: $java_home" -ForegroundColor Green

# Check Java
Write-Host "`n[*] Checking Java installation..." -ForegroundColor Yellow
$java_test = & "$java_home\bin\java" -version 2>&1 | Select-Object -First 1
Write-Host "[OK] Java found: $java_test" -ForegroundColor Green

# Navigate to project
Set-Location "C:\untitled"
Write-Host "`n[*] Working directory: $(Get-Location)" -ForegroundColor Yellow

# Build
Write-Host "`n[*] Starting Flutter build..." -ForegroundColor Yellow
Write-Host "Command: flutter build apk --debug" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

& flutter build apk --debug 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "[OK] BUILD SUCCESSFUL" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    
    $apk_path = "C:\untitled\build\app\outputs\flutter-apk\app-debug.apk"
    if (Test-Path $apk_path) {
        $size = [math]::Round((Get-Item $apk_path).Length / 1MB, 2)
        Write-Host "[OK] APK created successfully" -ForegroundColor Green
        Write-Host "Location: $apk_path" -ForegroundColor Green
        Write-Host "Size: $size MB" -ForegroundColor Green
    } else {
        Write-Host "`n[!] APK file not found at expected location" -ForegroundColor Yellow
        Write-Host "Expected: $apk_path" -ForegroundColor Yellow
        
        # Search for APK
        Write-Host "`n[*] Searching for APK files..." -ForegroundColor Yellow
        $apks = Get-ChildItem -Path "C:\untitled" -Filter "*.apk" -Recurse -ErrorAction SilentlyContinue
        if ($apks) {
            $apks | ForEach-Object {
                Write-Host "[OK] Found: $($_.FullName)" -ForegroundColor Green
            }
        } else {
            Write-Host "[X] No APK files found" -ForegroundColor Red
        }
    }
} else {
    Write-Host "`n========================================" -ForegroundColor Red
    Write-Host "[XX] BUILD FAILED" -ForegroundColor Red
    Write-Host "Exit Code: $LASTEXITCODE" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
}

Write-Host "`nBuild completed at $(Get-Date)" -ForegroundColor Cyan
