@echo off
setlocal EnableExtensions EnableDelayedExpansion
REM Build Zygisk .so for Render Switcher (Windows + Ninja)
REM
REM   set ANDROID_NDK_HOME=%LOCALAPPDATA%\Android\Sdk\ndk\30.0.16248370
REM   build.bat
REM   build.bat all
REM   build.bat arm64-v8a armeabi-v7a

cd /d "%~dp0"

if not defined ANDROID_NDK_HOME (
  if defined NDK_ROOT set "ANDROID_NDK_HOME=%NDK_ROOT%"
)
if not defined ANDROID_NDK_HOME (
  if defined ANDROID_NDK set "ANDROID_NDK_HOME=%ANDROID_NDK%"
)

if not defined ANDROID_NDK_HOME (
  echo ERROR: set ANDROID_NDK_HOME to your NDK path
  echo   set ANDROID_NDK_HOME=%%LOCALAPPDATA%%\Android\Sdk\ndk\30.0.16248370
  exit /b 1
)

if not exist "%ANDROID_NDK_HOME%\build\cmake\android.toolchain.cmake" (
  echo ERROR: invalid NDK path: %ANDROID_NDK_HOME%
  exit /b 1
)

set "SDK_ROOT=%ANDROID_NDK_HOME%\..\.."
for %%I in ("%SDK_ROOT%") do set "SDK_ROOT=%%~fI"

set "CMAKE_EXE="
set "NINJA_EXE="

if exist "%SDK_ROOT%\cmake" (
  for /f "delims=" %%D in ('dir /b /ad /o-n "%SDK_ROOT%\cmake" 2^>nul') do (
    if not defined CMAKE_EXE if exist "%SDK_ROOT%\cmake\%%D\bin\cmake.exe" set "CMAKE_EXE=%SDK_ROOT%\cmake\%%D\bin\cmake.exe"
    if not defined NINJA_EXE if exist "%SDK_ROOT%\cmake\%%D\bin\ninja.exe" set "NINJA_EXE=%SDK_ROOT%\cmake\%%D\bin\ninja.exe"
  )
)

if not defined CMAKE_EXE (
  where cmake >nul 2>&1 && for /f "delims=" %%P in ('where cmake') do if not defined CMAKE_EXE set "CMAKE_EXE=%%P"
)
if not defined NINJA_EXE (
  where ninja >nul 2>&1 && for /f "delims=" %%P in ('where ninja') do if not defined NINJA_EXE set "NINJA_EXE=%%P"
)

if not defined CMAKE_EXE (
  echo ERROR: cmake not found. Install CMake in Android Studio SDK Tools.
  exit /b 1
)
if not defined NINJA_EXE (
  echo ERROR: ninja not found. Install CMake in Android Studio SDK Tools.
  exit /b 1
)

echo Using cmake: %CMAKE_EXE%
echo Using ninja: %NINJA_EXE%
echo Using NDK:   %ANDROID_NDK_HOME%

set "API=26"
set "ABIS="

if "%~1"=="" (
  set "ABIS=arm64-v8a armeabi-v7a x86 x86_64"
) else if /I "%~1"=="all" (
  set "ABIS=arm64-v8a armeabi-v7a x86 x86_64"
) else (
  set "ABIS=%*"
)

for %%A in (%ABIS%) do (
  echo.
  echo === Building %%A ===
  set "BUILD_DIR=%~dp0build\%%A"
  if exist "!BUILD_DIR!" rmdir /s /q "!BUILD_DIR!"
  mkdir "!BUILD_DIR!" 2>nul

  "%CMAKE_EXE%" -S "%~dp0." -B "!BUILD_DIR!" -G Ninja ^
    -DCMAKE_MAKE_PROGRAM="%NINJA_EXE%" ^
    -DCMAKE_TOOLCHAIN_FILE="%ANDROID_NDK_HOME%/build/cmake/android.toolchain.cmake" ^
    -DANDROID_ABI=%%A ^
    -DANDROID_PLATFORM=android-%API% ^
    -DANDROID_STL=c++_static ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
  if errorlevel 1 (
    echo ERROR: cmake configure failed for %%A
    exit /b 1
  )

  "%CMAKE_EXE%" --build "!BUILD_DIR!" -j %NUMBER_OF_PROCESSORS%
  if errorlevel 1 (
    echo ERROR: cmake build failed for %%A
    exit /b 1
  )

  set "SO_OUT=%~dp0%%A.so"
  set "FOUND="

  REM Primary: CMake OUTPUT_NAME = ABI, PREFIX empty → build\ABI\ABI.so
  if exist "!BUILD_DIR!\%%A.so" (
    copy /Y "!BUILD_DIR!\%%A.so" "!SO_OUT!" >nul
    set "FOUND=1"
  )

  REM Fallback: librender_switcher_zygisk.so
  if not defined FOUND if exist "!BUILD_DIR!\librender_switcher_zygisk.so" (
    copy /Y "!BUILD_DIR!\librender_switcher_zygisk.so" "!SO_OUT!" >nul
    set "FOUND=1"
  )

  REM Fallback: any .so in build dir (one level)
  if not defined FOUND (
    for %%F in ("!BUILD_DIR!\*.so") do (
      if not defined FOUND (
        copy /Y "%%~fF" "!SO_OUT!" >nul
        set "FOUND=1"
      )
    )
  )

  REM Deep search last resort
  if not defined FOUND (
    for /f "delims=" %%F in ('dir /s /b "!BUILD_DIR!\*.so" 2^>nul') do (
      if not defined FOUND (
        copy /Y "%%F" "!SO_OUT!" >nul
        set "FOUND=1"
      )
    )
  )

  if not defined FOUND (
    echo ERROR: no .so produced for %%A
    echo Listing build dir:
    dir /s /b "!BUILD_DIR!"
    exit /b 1
  )

  if not exist "!SO_OUT!" (
    echo ERROR: copy failed to !SO_OUT!
    exit /b 1
  )
  echo OK  !SO_OUT!
)

echo.
echo Next:
echo   1. Put arm64-v8a.so (and other ABIs) inside module ZIP under zygisk\
echo   2. Flash/update module in Magisk
echo   3. Reboot ^(Zygisk must be ON^)
echo   4. Set per-app targets in WebUI
exit /b 0
