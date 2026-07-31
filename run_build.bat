@echo off
REM Set Java Home for Gradle
set "JAVA_HOME=C:\Program Files\Android\Android Studio\jbr"

REM Navigate to android directory and run build
cd /d "%~dp0android"
call gradlew.bat assembleDebug %*

pause
