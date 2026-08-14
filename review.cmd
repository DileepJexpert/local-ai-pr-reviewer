@echo off
setlocal EnableExtensions

echo.
echo =============================================
echo             LOCAL AI PR REVIEWER
echo =============================================
echo.
set /p PR_URL=Paste GitHub compare URL: 
set /p REPOSITORY=Local repository folder (example C:\work\katasticho): 
set /p CODER=AI executable [idfc-coder]: 
if "%CODER%"=="" set CODER=idfc-coder

if "%PR_URL%"=="" (
  echo A GitHub compare URL is required.
  exit /b 2
)
if "%REPOSITORY%"=="" (
  echo A local repository folder is required.
  exit /b 2
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-review.ps1" -Repository "%REPOSITORY%" -PrUrl "%PR_URL%" -Target main -CoderCommand "%CODER%" -OpenReport
set EXIT_CODE=%ERRORLEVEL%
echo.
if not "%EXIT_CODE%"=="0" echo Review did not complete. Check that your AI executable is installed and available in PATH.
pause
exit /b %EXIT_CODE%
