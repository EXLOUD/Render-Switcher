#!/system/bin/sh
# Render Switcher – renderer property abstraction
# Only touches debug.hwui.renderer. Fail-closed on invalid input.

renderer_get_global() {
    val=$(prop_get "debug.hwui.renderer" 2>/dev/null)
    if [ -z "$val" ]; then
        printf '%s\n' "${GLOBAL_RENDERER:-$DEFAULT_GLOBAL_RENDERER}"
        return 0
    fi
    printf '%s\n' "$val"
}

renderer_set_global() {
    renderer="$1"
    if ! is_valid_renderer "$renderer"; then
        log_error "renderer_set_global: invalid '$renderer'"
        return 1
    fi
    # Read the REAL property here. renderer_get_global() falls back to the
    # configured default when the prop is empty, which made a fresh boot look
    # "already set" and the property was never written.
    current=$(prop_get "debug.hwui.renderer" 2>/dev/null)
    if [ "$current" = "$renderer" ]; then
        log_info "renderer already $renderer (no-op)"
        return 0
    fi
    log_info "applying debug.hwui.renderer=$renderer"
    if ! prop_set "debug.hwui.renderer" "$renderer"; then
        log_error "failed to set debug.hwui.renderer=$renderer"
        return 5
    fi
    verified=$(prop_get "debug.hwui.renderer" 2>/dev/null)
    if [ "$verified" = "$renderer" ]; then
        log_info "verified debug.hwui.renderer=$renderer"
        return 0
    fi
    log_warn "verification mismatch: expected=$renderer got=$verified"
    return 5
}

renderer_restore_global() {
    target="${1:-${GLOBAL_RENDERER:-$DEFAULT_GLOBAL_RENDERER}}"
    is_valid_renderer "$target" || target="$DEFAULT_GLOBAL_RENDERER"
    log_info "restoring global renderer=$target"
    renderer_set_global "$target"
}

renderer_validate() {
    is_valid_renderer "$1"
}
