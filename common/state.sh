#!/system/bin/sh
# Render Switcher – persistent state (DATA_DIR outside module tree)

MODDIR="${MODDIR:-/data/adb/modules/render_switcher}"
DATA_DIR="${DATA_DIR:-/data/adb/render_switcher}"
CONFIG_DIR="${CONFIG_DIR:-${DATA_DIR}/config}"
MODULE_CONFIG_DIR="${MODULE_CONFIG_DIR:-${MODDIR}/config}"
LOG_FILE="${LOG_FILE:-${DATA_DIR}/render_switcher.log}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-131072}"
STATE_DIR="${STATE_DIR:-${DATA_DIR}/state}"
LOCK_DIR="${LOCK_DIR:-${DATA_DIR}/locks}"
TARGETS_CONF="${TARGETS_CONF:-${CONFIG_DIR}/targets.conf}"
SETTINGS_CONF="${SETTINGS_CONF:-${CONFIG_DIR}/settings.conf}"
BOOT_COUNTER="${BOOT_COUNTER:-${STATE_DIR}/boot_counter}"

DEFAULT_GLOBAL_RENDERER="skiavk"
ALLOWED_RENDERERS="skiavk skiagl"
BOOTLOOP_THRESHOLD=3

_LOG_READY=""

prepare_log() {
    [ "$_LOG_READY" = "$LOG_FILE" ] && return 0
    mkdir -p "${LOG_FILE%/*}" 2>/dev/null
    chmod 700 "${LOG_FILE%/*}" 2>/dev/null
    if [ -f "$LOG_FILE" ]; then
        SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
        if [ "${SIZE:-0}" -gt "$LOG_MAX_BYTES" ]; then
            mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null
            chmod 600 "${LOG_FILE}.1" 2>/dev/null
        fi
    fi
    touch "$LOG_FILE" 2>/dev/null
    chmod 600 "$LOG_FILE" 2>/dev/null
    _LOG_READY="$LOG_FILE"
}

append_log_line() {
    prepare_log
    echo "$1" >> "$LOG_FILE"
}

_PERSIST_READY=""

ensure_persistent_state() {
    # once per process is enough (load_settings/save_setting/target_* all call it)
    [ "$_PERSIST_READY" = "$DATA_DIR" ] && return 0
    mkdir -p "$DATA_DIR" "$CONFIG_DIR" "$STATE_DIR" "$LOCK_DIR" 2>/dev/null
    chmod 755 "$DATA_DIR" "$CONFIG_DIR" 2>/dev/null
    chmod 700 "$STATE_DIR" "$LOCK_DIR" 2>/dev/null
    prepare_log

    if [ ! -f "$TARGETS_CONF" ]; then
        if [ -f "${MODULE_CONFIG_DIR}/targets.conf" ]; then
            cp "${MODULE_CONFIG_DIR}/targets.conf" "$TARGETS_CONF" 2>/dev/null
        else
            {
                echo "# Render Switcher targets – package=renderer"
                echo "# Consumed by Zygisk companion for per-app isolation"
            } > "$TARGETS_CONF"
        fi
        chmod 644 "$TARGETS_CONF" 2>/dev/null
    fi

    if [ ! -f "$SETTINGS_CONF" ]; then
        if [ -f "${MODULE_CONFIG_DIR}/settings.conf" ]; then
            cp "${MODULE_CONFIG_DIR}/settings.conf" "$SETTINGS_CONF" 2>/dev/null
        else
            echo "GLOBAL_RENDERER=skiavk" > "$SETTINGS_CONF"
        fi
        chmod 600 "$SETTINGS_CONF" 2>/dev/null
    fi
    _PERSIST_READY="$DATA_DIR"
}

load_settings() {
    ensure_persistent_state
    GLOBAL_RENDERER="$DEFAULT_GLOBAL_RENDERER"
    ENFORCEMENT_DISABLED=""
    if [ -f "$SETTINGS_CONF" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ''|'#'*) continue ;;
            esac
            key=${line%%=*}
            val=${line#*=}
            case "$key" in
                GLOBAL_RENDERER) GLOBAL_RENDERER=$val ;;
                ENFORCEMENT_DISABLED) ENFORCEMENT_DISABLED=$val ;;
            esac
        done < "$SETTINGS_CONF"
    fi
}

save_setting() {
    key="$1"
    value="$2"
    ensure_persistent_state
    tmp="${SETTINGS_CONF}.tmp.$$"
    if [ -f "$SETTINGS_CONF" ]; then
        grep -v "^${key}=" "$SETTINGS_CONF" > "$tmp" 2>/dev/null || : > "$tmp"
    else
        : > "$tmp"
    fi
    echo "${key}=${value}" >> "$tmp"
    chmod 600 "$tmp" 2>/dev/null
    mv -f "$tmp" "$SETTINGS_CONF"
}
