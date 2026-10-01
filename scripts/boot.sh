#!/system/bin/sh
# Render Switcher – boot helpers (Zygisk only for per-app; no shell watcher)

MODDIR="${MODDIR:-${0%/*}/..}"
[ -f "${MODDIR}/common/state.sh" ] || MODDIR="/data/adb/modules/render_switcher"

. "${MODDIR}/common/state.sh"
. "${MODDIR}/common/utils.sh"
. "${MODDIR}/common/logging.sh"
. "${MODDIR}/common/properties.sh"
. "${MODDIR}/common/targets.sh"

boot_early() {
    # Module is being removed/disabled: do nothing, uninstall.sh cleans up
    if [ -f "${MODDIR}/remove" ] || [ -f "${MODDIR}/disable" ]; then
        return 0
    fi
    ensure_persistent_state
    load_settings
    _targets_sync_module

    if [ "${ENFORCEMENT_DISABLED}" = "1" ]; then
        log_warn "enforcement disabled (bootloop guard) – skipping global set"
        return 0
    fi

    renderer_set_global "${GLOBAL_RENDERER:-$DEFAULT_GLOBAL_RENDERER}"
    log_info "boot_early: global=$(renderer_get_global)"
}

boot_late() {
    if [ -f "${MODDIR}/remove" ] || [ -f "${MODDIR}/disable" ]; then
        return 0
    fi
    ensure_persistent_state
    load_settings
    _targets_sync_module

    counter=0
    [ -f "$BOOT_COUNTER" ] && counter=$(cat "$BOOT_COUNTER" 2>/dev/null || echo 0)
    counter=$((counter + 1))
    echo "$counter" > "$BOOT_COUNTER"

    if [ "$counter" -ge "$BOOTLOOP_THRESHOLD" ]; then
        log_error "bootloop protection: counter=$counter – disabling enforcement"
        save_setting "ENFORCEMENT_DISABLED" "1"
        return 1
    fi

    i=0
    while [ "$i" -lt 60 ]; do
        [ "$(prop_get sys.boot_completed 2>/dev/null)" = "1" ] && break
        sleep 1
        i=$((i + 1))
    done

    echo "0" > "$BOOT_COUNTER"
    log_info "boot_late: system ready (per-app via Zygisk only)"
}
