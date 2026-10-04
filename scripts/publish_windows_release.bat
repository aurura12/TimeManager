@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish_windows_release.ps1" %*
exit /b %ERRORLEVEL%
