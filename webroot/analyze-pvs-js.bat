@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM
REM Static analysis (PVS-Studio JS) for Render Switcher WebUI (script.js + locales).
REM
REM Usage:
REM   analyze-pvs-js.bat                 analyze current directory (webroot)
REM   analyze-pvs-js.bat path\to\webroot
REM
REM Requires: pvs-js (PVS-Studio 8.00+)
REM Optional: PlogConverter.exe for HTML report
REM
REM Output:
REM   pvs\reports\js\PVS-Studio.json
REM   pvs\reports\js\PVS-Studio.html   (if converter found)
REM
REM All diagnostic groups enabled (GA + OWASP). Certainty levels 1-3 included.

cd /d "%~dp0"
echo [INFO] analyze-pvs-js.bat started

if not "%~1"=="" (
  if exist "%~1\" (
    cd /d "%~1"
  ) else (
    echo [ERROR] Directory not found: %~1
    exit /b 1
  )
)

set "ROOT_DIR=%CD%"
set "PVS_DIR=%CD%\pvs"
set "REPORTS_DIR=%PVS_DIR%\reports\js"
set "JSON_REPORT=%REPORTS_DIR%\PVS-Studio.json"
set "HTML_REPORT=%REPORTS_DIR%\PVS-Studio.html"

REM Capture ProgramFiles paths early (avoid (x86) parse issues later)
set "PF86=%ProgramFiles(x86)%"
set "PF=%ProgramFiles%"

REM --- Locate pvs-js ---
set "PVSJS="
for /f "delims=" %%P in ('where pvs-js.exe 2^>nul') do if not defined PVSJS set "PVSJS=%%P"
if not defined PVSJS for /f "delims=" %%P in ('where pvs-js.cmd 2^>nul') do if not defined PVSJS set "PVSJS=%%P"
if not defined PVSJS if exist "!PF86!\PVS-Studio\pvs-js\pvs-js.exe" set "PVSJS=!PF86!\PVS-Studio\pvs-js\pvs-js.exe"
if not defined PVSJS if exist "!PF!\PVS-Studio\pvs-js\pvs-js.exe" set "PVSJS=!PF!\PVS-Studio\pvs-js\pvs-js.exe"
if not defined PVSJS if exist "!PF86!\PVS-Studio\pvs-js.exe" set "PVSJS=!PF86!\PVS-Studio\pvs-js.exe"
if not defined PVSJS if exist "!PF!\PVS-Studio\pvs-js.exe" set "PVSJS=!PF!\PVS-Studio\pvs-js.exe"

if not defined PVSJS (
  echo [ERROR] pvs-js not found.
  echo         Expected: !PF86!\PVS-Studio\pvs-js\pvs-js.exe
  exit /b 1
)

REM --- Optional converter ---
set "CONVERTER="
for /f "delims=" %%P in ('where PlogConverter.exe 2^>nul') do if not defined CONVERTER set "CONVERTER=%%P"
if not defined CONVERTER if exist "!PF86!\PVS-Studio\PlogConverter.exe" set "CONVERTER=!PF86!\PVS-Studio\PlogConverter.exe"
if not defined CONVERTER if exist "!PF!\PVS-Studio\PlogConverter.exe" set "CONVERTER=!PF!\PVS-Studio\PlogConverter.exe"

set "JOBS=%PVS_JOBS%"

echo [INFO] Project root: !ROOT_DIR!
echo [INFO] Analyzer:     !PVSJS!
if defined CONVERTER echo [INFO] Converter:    !CONVERTER!
if defined JOBS echo [INFO] Threads:      !JOBS!
echo [INFO] Rules:        ALL (GA + OWASP)

if not exist "!REPORTS_DIR!" mkdir "!REPORTS_DIR!"
if exist "!JSON_REPORT!" del "!JSON_REPORT!"
if exist "!HTML_REPORT!" del "!HTML_REPORT!"

echo [INFO] Running JS analysis...

REM Relative paths only. ALL diagnostics enabled.
if defined JOBS (
  "!PVSJS!" analyze "." --output "pvs\reports\js\PVS-Studio.json" --analysis-paths "analyze=*.js" --analysis-paths "skip-analysis=*/fonts/*" --rules ALL=on --threads !JOBS! --source-tree-root "."
) else (
  "!PVSJS!" analyze "." --output "pvs\reports\js\PVS-Studio.json" --analysis-paths "analyze=*.js" --analysis-paths "skip-analysis=*/fonts/*" --rules ALL=on --source-tree-root "."
)

set "RC=!ERRORLEVEL!"

if "!RC!"=="0" goto :analysis_ok
if "!RC!"=="1" (
  echo [WARN] Analysis finished with warnings (exit code 1).
  goto :analysis_ok
)
if "!RC!"=="5" (
  echo [WARN] Some files could not be analyzed (exit code 5). Report may be partial.
  goto :analysis_ok
)
if "!RC!"=="6" (
  echo [WARN] Some files timed out (exit code 6). Report may be partial.
  goto :analysis_ok
)
if "!RC!"=="20" (
  echo [ERROR] PVS-Studio license has expired (exit code 20).
  exit /b 1
)
if "!RC!"=="21" (
  echo [WARN] License expires in less than a month (exit code 21). Analysis completed.
  goto :analysis_ok
)
if "!RC!"=="22" (
  echo [ERROR] License missing or invalid (exit code 22).
  exit /b 1
)
if "!RC!"=="4" (
  echo [ERROR] All files were excluded from analysis (exit code 4).
  exit /b 1
)
echo [ERROR] pvs-js failed with exit code !RC!.
exit /b 1

:analysis_ok
if not exist "pvs\reports\js\PVS-Studio.json" (
  echo [ERROR] Analyzer did not produce pvs\reports\js\PVS-Studio.json
  exit /b 1
)

echo [INFO] JSON report: pvs\reports\js\PVS-Studio.json

if defined CONVERTER (
  echo [INFO] Converting report to HTML
  REM Include all certainty levels (1,2,3) for GA and OWASP
  "!CONVERTER!" "pvs\reports\js\PVS-Studio.json" -a "GA:1,2,3;OWASP:1,2,3" -t Html -o "pvs\reports\js" -n PVS-Studio
  if errorlevel 1 (
    echo [WARN] PlogConverter failed. JSON report kept.
  ) else if exist "pvs\reports\js\PVS-Studio.html" (
    echo [INFO] HTML report: pvs\reports\js\PVS-Studio.html
  ) else (
    echo [WARN] Expected HTML report was not produced.
  )
) else (
  echo [INFO] PlogConverter not found - skipping HTML generation.
)

echo [INFO] Done.
exit /b 0
