#!/usr/bin/env sh
# Render Switcher – static checks (run on host or device)
# Usage: sh scripts/check.sh

set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
fail=0
pass=0

ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

echo "== Shell syntax (bash -n) =="
for f in $(find . -type f -name '*.sh' | sort); do
  if bash -n "$f" 2>/dev/null; then
    ok "$f"
  else
    bad "$f"
    bash -n "$f" 2>&1 | sed 's/^/         /' || true
  fi
done

echo ""
echo "== JavaScript syntax =="
if command -v node >/dev/null 2>&1; then
  if node --check webroot/script.js 2>/dev/null; then
    ok "webroot/script.js"
  else
    bad "webroot/script.js"
    node --check webroot/script.js 2>&1 | sed 's/^/         /' || true
  fi
else
  echo "  SKIP  node not installed"
fi

echo ""
echo "== shellcheck (optional) =="
if command -v shellcheck >/dev/null 2>&1; then
  for f in bin/skiactl common/*.sh scripts/*.sh customize.sh uninstall.sh post-fs-data.sh service.sh; do
    [ -f "$f" ] || continue
    if shellcheck -x -e SC1091,SC2039,SC3043 "$f" 2>/dev/null; then
      ok "shellcheck $f"
    else
      bad "shellcheck $f"
      shellcheck -x -e SC1091,SC2039,SC3043 "$f" 2>&1 | sed 's/^/         /' | head -20 || true
    fi
  done
else
  echo "  SKIP  shellcheck not installed (apt/brew install shellcheck)"
fi

echo ""
echo "== module.prop =="
if grep -q '^id=render_switcher$' module.prop && grep -q '^name=Render Switcher$' module.prop; then
  ok "module.prop id/name"
else
  bad "module.prop id/name"
fi
if grep -q '^banner=banner.jpg$' module.prop && [ -f banner.jpg ]; then
  ok "banner.jpg present"
else
  bad "banner.jpg missing or prop mismatch"
fi

echo ""
echo "== Package validation unit smoke =="
# shellcheck source=common/utils.sh
. ./common/utils.sh 2>/dev/null || . "$ROOT/common/utils.sh"
# LOCK_DIR not needed for pure validation
smoke_ok=1
is_valid_package "com.example.app" || smoke_ok=0
is_valid_package "com..bad" && smoke_ok=0
is_valid_package "../evil" && smoke_ok=0
is_valid_package "a;rm" && smoke_ok=0
is_valid_package "com." && smoke_ok=0
is_valid_renderer "skiavk" || smoke_ok=0
is_valid_renderer "opengl" && smoke_ok=0
if [ "$smoke_ok" -eq 1 ]; then
  ok "is_valid_package / is_valid_renderer"
else
  bad "is_valid_package / is_valid_renderer"
fi

echo ""
echo "== Targets unit test (mock env) =="
if [ -f tests/test_targets.sh ]; then
  if sh tests/test_targets.sh; then
    ok "tests/test_targets.sh"
  else
    bad "tests/test_targets.sh"
  fi
else
  echo "  SKIP  tests/test_targets.sh missing"
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
