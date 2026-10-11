@echo off
setlocal
where node >nul 2>&1
if errorlevel 1 (
  echo Node.js 22 or newer is required. Install Node.js, then open this file again.
  pause
  exit /b 1
)
node "%~dp0..\..\runtime\router.mjs" %*
set "forgepilot_exit=%ERRORLEVEL%"
if not "%forgepilot_exit%"=="0" pause
exit /b %forgepilot_exit%
