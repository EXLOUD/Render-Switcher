#!/system/bin/sh
set -e
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export MODDIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
echo "TEST MODDIR=$MODDIR"
. "$SCRIPT_DIR/mock/mock_env.sh"

pass=0; fail=0
ok() { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

# --- validation unit ---
is_valid_package "com.example.game" && ok "pkg ok" || bad "pkg ok"
is_valid_package "com..bad" && bad "pkg dots" || ok "pkg dots"
is_valid_package "../x" && bad "pkg path" || ok "pkg path"
is_valid_package "a;b.c" && bad "pkg meta" || ok "pkg meta"
is_valid_package "com." && bad "pkg trailing" || ok "pkg trailing"
is_valid_package ".com.app" && bad "pkg leading" || ok "pkg leading"
is_valid_package "1com.app" && bad "pkg digit-seg" || ok "pkg digit-seg"
is_valid_renderer "skiavk" && ok "ren ok" || bad "ren ok"
is_valid_renderer "vulkan" && bad "ren bad" || ok "ren bad"

target_clear
target_add com.example.game skiavk
target_exists com.example.game && ok "exists" || bad "exists"
[ "$(target_get_renderer com.example.game)" = skiavk ] && ok "renderer" || bad "renderer"

target_add com.example.game skiagl
[ "$(target_get_renderer com.example.game)" = skiagl ] && ok "update" || bad "update"

target_add invalid skiavk 2>/dev/null && bad "bad pkg" || ok "bad pkg"
target_add com.ok opengl 2>/dev/null && bad "bad ren" || ok "bad ren"
target_add "com..evil" skiavk 2>/dev/null && bad "dbl-dot pkg" || ok "dbl-dot pkg"

target_remove com.example.game
target_exists com.example.game && bad "removed" || ok "removed"

echo "com.bad=evil;rm -rf /" > "$TARGETS_CONF"
target_validate && bad "validate" || ok "validate"

rm -rf "$DATA_DIR"
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
