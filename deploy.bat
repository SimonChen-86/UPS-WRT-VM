@echo off
chcp 65001 >nul
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\deploy.ps1"
if %errorlevel% neq 0 (
    echo.
    echo [ERROR] 部署向导异常退出，退出码: %errorlevel%
    pause
)
