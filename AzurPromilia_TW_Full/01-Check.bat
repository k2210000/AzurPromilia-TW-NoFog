@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0Candidate.ps1" -Action Check -GameRoot "%~1"
set "RC=%ERRORLEVEL%"
echo Exit code: %RC%
pause
exit /b %RC%
