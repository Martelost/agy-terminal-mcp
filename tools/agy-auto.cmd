@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0agy-auto.ps1" %*
exit /b %ERRORLEVEL%
