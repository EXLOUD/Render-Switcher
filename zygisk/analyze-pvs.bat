@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM
REM Static analysis (PVS-Studio) for the Render Switcher Zygisk library,
REM run over already configured build\ABI\ directories (Android NDK cross-compile).
REM
REM Deliberately NOT part of build.bat: analysis is much slower than a normal
REM build, so it is a separate step:
REM
REM   build.bat                        build all ABIs (creates compile_commands.json)
REM   analyze-pvs.bat                  analyze ALL ABIs (default)
REM   analyze-pvs.bat arm64-v8a        analyze only the listed ABI(s)
REM
REM No PVS-Studio.cmake needed: CompilerCommandsAnalyzer.exe and
REM PlogConverter.exe are called directly on build\ABI\compile_commands.json
REM (exported by CMakeLists.txt: CMAKE_EXPORT_COMPILE_COMMANDS; build.bat uses Ninja).
REM
REM Output (per ABI):
REM   pvs\reports\ABI\PVS-Studio.html   open in a browser
REM   pvs\reports\ABI\PVS-Studio.json   for CI / IDE import
REM
REM Optional files in pvs\ (picked up if present):
REM   PVS-Studio.cfg               analyzer launch parameters
REM   .pvsconfig                   diagnostic rules
REM   suppress_file.suppress.json  baseline of suppressed warnings
REM
REM Environment variables:
REM   PVS_COMPILER=NAME=TYPE       force compiler type if not recognized (e.g. clang++=clang)
REM   PVS_JOBS=N                   threads (default NUMBER_OF_PROCESSORS)
REM   ANDROID_NDK_HOME             NDK is excluded from analysis (optional)
REM
REM Exit code: 0 = all ABIs analyzed, 1 = at least one ABI failed.

cd /d "%~dp0"
echo [INFO] analyze-pvs.bat started
set "ROOT_DIR=%CD%"
set "PVS_DIR=%ROOT_DIR%\pvs"

set "ABIS="
if "%~1"=="" (
  set "ABIS=arm64-v8a armeabi-v7a x86 x86_64"
) else if /I "%~1"=="all" (
  set "ABIS=arm64-v8a armeabi-v7a x86 x86_64"
) else (
  set "ABIS=%*"
)

REM --- Locate PVS-Studio tools once: PATH first, then default install dirs ---
call :find_tool ANALYZER CompilerCommandsAnalyzer.exe
call :find_tool CONVERTER PlogConverter.exe

if not defined ANALYZER (
  echo [ERROR] CompilerCommandsAnalyzer.exe not found. Install PVS-Studio for Windows and make sure it is on PATH.
  exit /b 1
)
if not defined CONVERTER (
  echo [ERROR] PlogConverter.exe not found. It ships alongside the analyzer in the same PVS-Studio install.
  exit /b 1
)

if not defined ANDROID_NDK_HOME if defined NDK_ROOT set "ANDROID_NDK_HOME=%NDK_ROOT%"
if not defined ANDROID_NDK_HOME if defined ANDROID_NDK set "ANDROID_NDK_HOME=%ANDROID_NDK%"

set "JOBS=%PVS_JOBS%"
if not defined JOBS set "JOBS=%NUMBER_OF_PROCESSORS%"
if not defined JOBS set "JOBS=4"

echo [INFO] Project root: %ROOT_DIR%
echo [INFO] ABIs:         %ABIS%
echo [INFO] Analyzer:     %ANALYZER%
echo [INFO] Converter:    %CONVERTER%

set "FAILED="
for %%A in (%ABIS%) do (
  echo.
  echo === Analyzing %%A ===
  call :analyze_one %%A
  if errorlevel 1 set "FAILED=!FAILED! %%A"
)

echo.
if defined FAILED (
  echo [ERROR] Analysis failed for:%FAILED%
  exit /b 1
)
echo [INFO] All ABIs analyzed. Reports: %PVS_DIR%\reports\ABI\PVS-Studio.html
exit /b 0

REM ---------------------------------------------------------------------------
REM :analyze_one ABI
:analyze_one
setlocal EnableExtensions EnableDelayedExpansion
set "ABI=%~1"

set "PLATFORM="
if /I "%ABI%"=="arm64-v8a"   set "PLATFORM=linux64"
if /I "%ABI%"=="x86_64"      set "PLATFORM=linux64"
if /I "%ABI%"=="armeabi-v7a" set "PLATFORM=linux32"
if /I "%ABI%"=="x86"         set "PLATFORM=linux32"
if not defined PLATFORM (
  echo [ERROR] unknown ABI "%ABI%" ^(supported: arm64-v8a armeabi-v7a x86 x86_64^)
  exit /b 1
)

set "BUILD_DIR=%ROOT_DIR%\build\%ABI%"
set "REPORTS_DIR=%PVS_DIR%\reports\%ABI%"
set "COMPILE_COMMANDS=%BUILD_DIR%\compile_commands.json"
set "RAW_LOG=%REPORTS_DIR%\PVS-Studio.raw.log"

if not exist "%COMPILE_COMMANDS%" (
  echo [ERROR] compile_commands.json not found at %COMPILE_COMMANDS%
  echo         Build first: build.bat %ABI%
  exit /b 1
)

if not exist "%ROOT_DIR%\%ABI%.so" echo [WARN] %ABI%.so is missing - the last build may have failed.

if not exist "%REPORTS_DIR%" mkdir "%REPORTS_DIR%"
if exist "%RAW_LOG%" del "%RAW_LOG%"
if exist "%REPORTS_DIR%\PVS-Studio.html" del "%REPORTS_DIR%\PVS-Studio.html"
if exist "%REPORTS_DIR%\PVS-Studio.json" del "%REPORTS_DIR%\PVS-Studio.json"

REM -e build: exclude build artifacts. Third-party src\zygisk.hpp is excluded
REM in pvs\.pvsconfig. NDK headers (-isystem) are skipped by the analyzer itself,
REM but the NDK is excluded as well just in case.
set ARGS=analyze -f "%COMPILE_COMMANDS%" -o "%RAW_LOG%" -e "%ROOT_DIR%\build" -e "%ROOT_DIR%\src\zygisk.hpp" --platform %PLATFORM% -j%JOBS%
if defined ANDROID_NDK_HOME set ARGS=!ARGS! -e "%ANDROID_NDK_HOME%"

if exist "%PVS_DIR%\PVS-Studio.cfg"              set ARGS=!ARGS! --cfg "%PVS_DIR%\PVS-Studio.cfg"
if exist "%PVS_DIR%\.pvsconfig"                  set ARGS=!ARGS! -R "%PVS_DIR%\.pvsconfig"
if exist "%PVS_DIR%\suppress_file.suppress.json" set ARGS=!ARGS! -s "%PVS_DIR%\suppress_file.suppress.json"
if defined PVS_COMPILER                          set ARGS=!ARGS! --compiler "%PVS_COMPILER%"

echo [INFO] %ABI% ^(%PLATFORM%^): running analysis ^(-j%JOBS%^)
"%ANALYZER%" !ARGS!
set "RC=%ERRORLEVEL%"

if "%RC%"=="0" goto :analysis_ok
if "%RC%"=="2" (
  echo [WARN] PVS-Studio license expires in less than a month ^(exit code 2^). Analysis itself completed.
  goto :analysis_ok
)
if "%RC%"=="3" (
  echo [WARN] Internal analyzer error on some files ^(exit code 3^). The report is partial.
  goto :analysis_ok
)
if "%RC%"=="5" (
  echo [ERROR] PVS-Studio license has expired ^(exit code 5^).
  exit /b 1
)
if "%RC%"=="7" (
  echo [ERROR] No compilation units were accepted for analysis ^(exit code 7^). Check the -e exclusions and compile_commands.json.
  exit /b 1
)
if "%RC%"=="8" (
  echo [ERROR] No compiler invocations detected ^(exit code 8^). The NDK clang was not recognized -
  echo         try: set PVS_COMPILER=clang++=clang ^& analyze-pvs.bat
  exit /b 1
)
echo [ERROR] CompilerCommandsAnalyzer failed with exit code %RC%.
exit /b 1

:analysis_ok
if not exist "%RAW_LOG%" (
  echo [ERROR] Analyzer did not produce %RAW_LOG%.
  exit /b 1
)

echo [INFO] Converting report to HTML + JSON
"%CONVERTER%" "%RAW_LOG%" -a "GA:1,2,3;64:1,2,3;OP:1,2,3" -t Html,Json -o "%REPORTS_DIR%" -n PVS-Studio
if errorlevel 1 (
  echo [ERROR] PlogConverter failed. Raw report kept at %RAW_LOG%
  exit /b 1
)

del "%RAW_LOG%" >nul 2>&1

if not exist "%REPORTS_DIR%\PVS-Studio.html" echo [WARN] Expected report was not produced: %REPORTS_DIR%\PVS-Studio.html
if not exist "%REPORTS_DIR%\PVS-Studio.json" echo [WARN] Expected report was not produced: %REPORTS_DIR%\PVS-Studio.json

echo [INFO] %REPORTS_DIR%\PVS-Studio.html
exit /b 0

REM ---------------------------------------------------------------------------
REM :find_tool OUT_VAR EXE_NAME
:find_tool
set "%~1="
for /f "delims=" %%P in ('where %~2 2^>nul') do if not defined %~1 set "%~1=%%P"
if defined %~1 exit /b 0
for %%B in ("%ProgramFiles(x86)%\PVS-Studio" "%ProgramFiles%\PVS-Studio") do (
  if not defined %~1 if exist "%%~B\%~2" set "%~1=%%~B\%~2"
)
exit /b 0
