#!/usr/bin/env bash
# Build Zygisk .so for Render Switcher
#
# Requirements:
#   - Android NDK r25+ (r26/r27 recommended)
#   - cmake 3.18+
#
# Usage:
#   export ANDROID_NDK_HOME=/path/to/ndk
#   ./build.sh              # all ABIs (default)
#   ./build.sh all          # all ABIs: arm64-v8a, armeabi-v7a, x86, x86_64
#   ./build.sh arm64-v8a armeabi-v7a   # specific ABIs
#
# Output:
#   zygisk/arm64-v8a.so
#   zygisk/armeabi-v7a.so
#   zygisk/x86.so
#   zygisk/x86_64.so

set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"

NDK="${ANDROID_NDK_HOME:-${NDK_ROOT:-${ANDROID_NDK:-}}}"
if [ -z "$NDK" ] || [ ! -f "$NDK/build/cmake/android.toolchain.cmake" ]; then
  echo "ERROR: set ANDROID_NDK_HOME to your NDK path"
  echo "  export ANDROID_NDK_HOME=\$HOME/Android/Sdk/ndk/27.0.12077973"
  exit 1
fi

API=26
ALL_ABIS=("arm64-v8a" "armeabi-v7a" "x86" "x86_64")

if [ $# -eq 0 ]; then
  ABIS=("${ALL_ABIS[@]}")
elif [ "${1:-}" = "all" ]; then
  ABIS=("${ALL_ABIS[@]}")
else
  ABIS=("$@")
fi

for ABI in "${ABIS[@]}"; do
  case "$ABI" in
    arm64-v8a|armeabi-v7a|x86|x86_64) ;;
    *)
      echo "ERROR: unknown ABI '$ABI' (supported: ${ALL_ABIS[*]})"
      exit 1
      ;;
  esac

  BUILD_DIR="$ROOT/build/$ABI"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  cmake -S "$ROOT" -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="android-$API" \
    -DANDROID_STL=c++_static \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
  cmake --build "$BUILD_DIR" -j"$(nproc 2>/dev/null || echo 4)"

  # Magisk expects zygisk/<abi>.so at module root of zygisk/
  SO_SRC=$(find "$BUILD_DIR" -name '*.so' | head -1)
  if [ -z "$SO_SRC" ]; then
    echo "ERROR: no .so produced for $ABI"
    exit 1
  fi
  cp -f "$SO_SRC" "$ROOT/${ABI}.so"
  echo "OK  $ROOT/${ABI}.so ($(wc -c < "$ROOT/${ABI}.so") bytes)"
done

echo ""
echo "Built ABIs: ${ABIS[*]}"
echo "Next:"
echo "  1. Ensure these files are inside the module ZIP under zygisk/"
echo "  2. Flash/update module in Magisk"
echo "  3. Reboot (Zygisk must be ON)"
echo "  4. Set per-app targets in WebUI"
