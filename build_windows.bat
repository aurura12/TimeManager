@echo off
cd /d "%~dp0"

echo ============================================
echo  time_manager Windows build script
echo ============================================

echo.
echo [1/4] Check nuget.exe (required by geolocator plugin)
set "NUGET_DIR=build\windows\x64\_deps\nuget-subbuild\nuget-populate-prefix\src"
if exist "%NUGET_DIR%\nuget.exe" goto nuget_ok
echo   nuget.exe not found, downloading...
if not exist "%NUGET_DIR%" mkdir "%NUGET_DIR%"
curl -sSL -o "%NUGET_DIR%\nuget.exe" "https://dist.nuget.org/win-x86-commandline/v6.0.0/nuget.exe"
if not errorlevel 1 goto nuget_ok
echo   [ERROR] Failed to download nuget.exe
echo   Download it manually to: %NUGET_DIR%\nuget.exe
echo   URL: https://dist.nuget.org/win-x86-commandline/v6.0.0/nuget.exe
pause
exit /b 1
:nuget_ok
echo   nuget.exe ready

echo.
echo [2/4] Build Windows release...
call flutter build windows --release
if not errorlevel 1 goto build_ok
echo   [ERROR] Build failed!
pause
exit /b 1
:build_ok
echo   OK: build\windows\x64\runner\Release\

echo.
echo [3/4] Check Inno Setup and build installer
set "ISCC="
if exist "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" set "ISCC=C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
if exist "C:\Program Files\Inno Setup 6\ISCC.exe" set "ISCC=C:\Program Files\Inno Setup 6\ISCC.exe"
if not defined ISCC goto no_iscc
echo   Using %ISCC%
"%ISCC%" installer.iss
if not errorlevel 1 goto iscc_ok
echo   [ERROR] Installer build failed!
pause
exit /b 1
:iscc_ok
echo   OK: installer_output\
goto iscc_done
:no_iscc
echo   [WARN] Inno Setup not found, skip installer packaging
echo   Install from https://jrsoftware.org/isinfo.php
:iscc_done

echo.
echo [4/4] Check version
for /f "tokens=2 delims= " %%v in ('findstr /b "version:" pubspec.yaml') do set "PUBSPEC_VER=%%v"
echo   pubspec.yaml version: %PUBSPEC_VER%
echo   Make sure installer.iss MyAppVersion matches.

echo.
echo Done!
pause
