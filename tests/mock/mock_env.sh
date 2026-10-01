#!/system/bin/sh
if [ -z "$MODDIR" ] || [ ! -d "$MODDIR/common" ]; then
    THIS=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
    [ -n "$THIS" ] && MODDIR=$(CDPATH= cd -- "$THIS/../.." && pwd)
fi
[ -d "$MODDIR/common" ] || MODDIR="/data/adb/modules/render_switcher"
export MODDIR

export DATA_DIR="/tmp/render_switcher_test_$$"
export CONFIG_DIR="${DATA_DIR}/config"
export STATE_DIR="${DATA_DIR}/state"
export LOCK_DIR="${DATA_DIR}/locks"
export TARGETS_CONF="${CONFIG_DIR}/targets.conf"
export SETTINGS_CONF="${CONFIG_DIR}/settings.conf"
export LOG_FILE="${DATA_DIR}/test.log"
export LOG_MAX_BYTES=1048576
export DEFAULT_GLOBAL_RENDERER=skiavk
export CYCLE_DIR="${STATE_DIR}/cycles"
export ACTIVE_STATE="${STATE_DIR}/active_targets"
export BOOT_COUNTER="${STATE_DIR}/boot_counter"
export RENDERTHREAD_TIMEOUT=5
export PROCESS_EXIT_TIMEOUT=10

mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$LOCK_DIR" "$CYCLE_DIR"

prop_get() { echo "${MOCK_PROP:-skiavk}"; }
prop_set() { MOCK_PROP=$2; return 0; }
has_cmd() { return 0; }

. "$MODDIR/common/state.sh"
. "$MODDIR/common/utils.sh"
. "$MODDIR/common/logging.sh"
. "$MODDIR/common/targets.sh"

echo "Mock ready DATA_DIR=$DATA_DIR MODDIR=$MODDIR"
