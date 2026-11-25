@echo off
cd /d __WD__
if not exist "__WD__\watchdog-main.ps1" (echo [守护] 脚本缺失 & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File "__WD__\watchdog-main.ps1"
