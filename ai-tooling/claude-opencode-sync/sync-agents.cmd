@echo off
rem Usage: sync-agents.cmd [ToOpenCode|ToClaude|Both] [-DryRun] [-Force]
rem No arguments = interactive menu.
setlocal
if not "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-agents.ps1" -Direction %*
  goto :end
)
echo.
echo  1) Claude   -^> OpenCode
echo  2) OpenCode -^> Claude
echo  3) Both ways
echo  4) Dry run, both ways (change nothing)
echo.
choice /c 1234 /n /m "Pick: "
if errorlevel 4 powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-agents.ps1" -Direction Both -DryRun & goto :end
if errorlevel 3 powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-agents.ps1" -Direction Both & goto :end
if errorlevel 2 powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-agents.ps1" -Direction ToClaude & goto :end
if errorlevel 1 powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-agents.ps1" -Direction ToOpenCode
:end
pause
