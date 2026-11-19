@echo off
rem agent-sync: keep Claude Code + OpenCode in sync via the master in the tech-wiki repo.
rem Usage: agent-sync.cmd [Sync|Pull|Push|Status] [-Prefer Local|Repo] [-DryRun]
rem No arguments = menu.
setlocal
set PS=powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0agent-sync.ps1"
if not "%~1"=="" (
  %PS% -Action %*
  goto :end
)
echo.
echo  1) Sync   (pull master + push new local things, both ways)
echo  2) Pull   (master -^> this machine)
echo  3) Push   (this machine -^> master)
echo  4) Status (show differences, change nothing)
echo.
choice /c 1234 /n /m "Pick: "
if errorlevel 4 %PS% -Action Status & goto :end
if errorlevel 3 %PS% -Action Push & goto :end
if errorlevel 2 %PS% -Action Pull & goto :end
if errorlevel 1 %PS% -Action Sync
:end
pause
