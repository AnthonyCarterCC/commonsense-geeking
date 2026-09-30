@echo off
setlocal

rem ---------------------------------------------------------------------
rem Run-PromoteToLocalAdmin.bat
rem
rem Double-click launcher for Promote-CurrentUserToLocalAdmin.ps1
rem   - Re-launches itself elevated (UAC prompt) if not already admin.
rem     NOTE: you'll need to approve the UAC prompt with an account that
rem     already has local admin rights (e.g. a break-glass admin account),
rem     since the standard AAD user being promoted cannot self-elevate.
rem   - Unblocks the .ps1 (clears the "downloaded from the internet" flag).
rem   - Runs it with ExecutionPolicy Bypass scoped to this process only.
rem ---------------------------------------------------------------------

set "SCRIPT_DIR=%~dp0"
set "PS1_PATH=%SCRIPT_DIR%Promote-CurrentUserToLocalAdmin.ps1"

rem --- Check for admin rights; if missing, relaunch elevated ---
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

if not exist "%PS1_PATH%" (
    echo ERROR: Could not find "%PS1_PATH%".
    echo Make sure Run-PromoteToLocalAdmin.bat and Promote-CurrentUserToLocalAdmin.ps1
    echo are extracted into the same folder.
    pause
    exit /b 1
)

echo Unblocking script...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -Path '%PS1_PATH%'"

echo Running Promote-CurrentUserToLocalAdmin.ps1 ...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1_PATH%" %*

echo.
echo Done. Press any key to close this window.
pause >nul
