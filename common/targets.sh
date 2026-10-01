#!/system/bin/sh
# Render Switcher – Target Apps Manager (single source of truth)
# Format in targets.conf:
#   package=renderer
#   package=renderer:0   (disabled)
# Comments and blank lines ignored. Atomic writes only.

_targets_parse_line() (
    line="$1"
    line=$(printf '%s' "$line" | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && exit 1

    package=${line%%=*}
    rest=${line#*=}
    package=$(trim "$package")
    rest=$(trim "$rest")

    is_valid_package "$package" || exit 1

    renderer=${rest%%:*}
    enabled=${rest#*:}
    [ "$renderer" = "$rest" ] && enabled=1
    renderer=$(trim "$renderer")
    enabled=$(trim "$enabled")

    is_valid_renderer "$renderer" || exit 1
    case "$enabled" in
        0|false|no|off) enabled=0 ;;
        *) enabled=1 ;;
    esac
    printf '%s|%s|%s\n' "$package" "$renderer" "$enabled"
)

_targets_validate_file() (
    f="$1"
    [ -f "$f" ] || exit 0
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(printf '%s' "$line" | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$line" ] && continue
        _targets_parse_line "$line" >/dev/null || exit 1
    done < "$f"
    exit 0
)


# Zygisk runs in a mount namespace where only the module tree is reliably visible.
# Keep a mirror next to the .so so preAppSpecialize can read targets.
_MODULE_TARGETS="/data/adb/modules/render_switcher/targets.conf"
_targets_sync_module() {
    # Mirror must always equal TARGETS_CONF, otherwise Zygisk (reads the mirror
    # first) keeps applying a renderer for an app that is no longer in the list.
    [ -d "${_MODULE_TARGETS%/*}" ] || return 0
    if [ -f "$TARGETS_CONF" ]; then
        cp -f "$TARGETS_CONF" "$_MODULE_TARGETS" 2>/dev/null
        chmod 644 "$_MODULE_TARGETS" 2>/dev/null
    else
        rm -f "$_MODULE_TARGETS" 2>/dev/null
    fi
}

_targets_write_atomic() {
    # stdin: lines package|renderer|enabled
    ensure_persistent_state
    tmp="${TARGETS_CONF}.tmp.$$"
    : > "$tmp"
    while IFS= read -r entry || [ -n "$entry" ]; do
        [ -z "$entry" ] && continue
        p=$(printf '%s' "$entry" | cut -d'|' -f1)
        r=$(printf '%s' "$entry" | cut -d'|' -f2)
        e=$(printf '%s' "$entry" | cut -d'|' -f3)
        if [ "$e" = "1" ]; then
            echo "${p}=${r}" >> "$tmp"
        else
            echo "${p}=${r}:0" >> "$tmp"
        fi
    done
    if ! _targets_validate_file "$tmp"; then
        rm -f "$tmp"
        log_error "targets write validation failed"
        return 3
    fi
    chmod 644 "$tmp" 2>/dev/null
    mv -f "$tmp" "$TARGETS_CONF" || { rm -f "$tmp"; return 3; }
    _targets_sync_module
    return 0
}

target_exists() {
    is_valid_package "$1" || return 1
    [ -f "$TARGETS_CONF" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        parsed=$(_targets_parse_line "$line") || continue
        p=$(printf '%s' "$parsed" | cut -d'|' -f1)
        [ "$p" = "$1" ] && return 0
    done < "$TARGETS_CONF"
    return 1
}

target_get_renderer() {
    is_valid_package "$1" || return 1
    [ -f "$TARGETS_CONF" ] || return 2
    while IFS= read -r line || [ -n "$line" ]; do
        parsed=$(_targets_parse_line "$line") || continue
        p=$(printf '%s' "$parsed" | cut -d'|' -f1)
        r=$(printf '%s' "$parsed" | cut -d'|' -f2)
        if [ "$p" = "$1" ]; then
            printf '%s\n' "$r"
            return 0
        fi
    done < "$TARGETS_CONF"
    return 2
}

target_is_enabled() {
    is_valid_package "$1" || return 1
    [ -f "$TARGETS_CONF" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        parsed=$(_targets_parse_line "$line") || continue
        p=$(printf '%s' "$parsed" | cut -d'|' -f1)
        e=$(printf '%s' "$parsed" | cut -d'|' -f3)
        if [ "$p" = "$1" ]; then
            [ "$e" = "1" ] && return 0 || return 1
        fi
    done < "$TARGETS_CONF"
    return 1
}

target_add() {
    package="$1"
    renderer="$2"
    is_valid_package "$package" || { log_error "invalid package"; return 1; }
    is_valid_renderer "$renderer" || { log_error "invalid renderer"; return 1; }

    ensure_persistent_state
    tmp_list="${CONFIG_DIR}/.tl.$$"
    : > "$tmp_list"
    found=0
    if [ -f "$TARGETS_CONF" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            parsed=$(_targets_parse_line "$line") || continue
            p=$(printf '%s' "$parsed" | cut -d'|' -f1)
            if [ "$p" = "$package" ]; then
                echo "${package}|${renderer}|1" >> "$tmp_list"
                found=1
            else
                echo "$parsed" >> "$tmp_list"
            fi
        done < "$TARGETS_CONF"
    fi
    [ "$found" = "0" ] && echo "${package}|${renderer}|1" >> "$tmp_list"

    if _targets_write_atomic < "$tmp_list"; then
        rm -f "$tmp_list"
        log_info "target: $package -> $renderer"
        return 0
    fi
    rm -f "$tmp_list"
    return 3
}

target_remove() {
    package="$1"
    is_valid_package "$package" || return 1
    ensure_persistent_state
    [ -f "$TARGETS_CONF" ] || return 0

    # Simple line filter — no pipe-to-function, exact prefix match on package=
    # (avoids flaky write paths that left the entry in targets.conf)
    tmp="${TARGETS_CONF}.tmp.$$"
    : > "$tmp"
    while IFS= read -r line || [ -n "$line" ]; do
        stripped=$(printf '%s' "$line" | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -z "$stripped" ]; then
            # keep blank/comment-only lines as-is
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        case "$stripped" in
            "${package}="*) ;; # drop this target
            *) printf '%s\n' "$line" >> "$tmp" ;;
        esac
    done < "$TARGETS_CONF"

    chmod 644 "$tmp" 2>/dev/null
    if ! mv -f "$tmp" "$TARGETS_CONF"; then
        rm -f "$tmp"
        log_error "target remove mv failed: $package"
        return 3
    fi
    _targets_sync_module
    log_info "target removed: $package"
    return 0
}

target_set_renderer() {
    package="$1"
    renderer="$2"
    is_valid_package "$package" || return 1
    is_valid_renderer "$renderer" || return 1
    target_exists "$package" || return 2

    ensure_persistent_state
    tmp_list="${CONFIG_DIR}/.tl.$$"
    : > "$tmp_list"
    while IFS= read -r line || [ -n "$line" ]; do
        parsed=$(_targets_parse_line "$line") || continue
        p=$(printf '%s' "$parsed" | cut -d'|' -f1)
        if [ "$p" = "$package" ]; then
            # keep the enabled flag (last field) – only the renderer changes
            en=$(printf '%s' "$parsed" | cut -d'|' -f3)
            echo "${package}|${renderer}|${en}" >> "$tmp_list"
        else
            echo "$parsed" >> "$tmp_list"
        fi
    done < "$TARGETS_CONF"

    if _targets_write_atomic < "$tmp_list"; then
        rm -f "$tmp_list"
        log_info "target: $package -> $renderer"
        return 0
    fi
    rm -f "$tmp_list"
    return 3
}

target_set_enabled() {
    package="$1"
    state="$2"
    case "$state" in
        1|true|yes|on) state=1 ;;
        0|false|no|off) state=0 ;;
        *) return 1 ;;
    esac
    target_exists "$package" || return 2
    renderer=$(target_get_renderer "$package") || return 2

    tmp_list="${CONFIG_DIR}/.tl.$$"
    : > "$tmp_list"
    while IFS= read -r line || [ -n "$line" ]; do
        parsed=$(_targets_parse_line "$line") || continue
        p=$(printf '%s' "$parsed" | cut -d'|' -f1)
        r=$(printf '%s' "$parsed" | cut -d'|' -f2)
        if [ "$p" = "$package" ]; then
            echo "${package}|${renderer}|${state}" >> "$tmp_list"
        else
            echo "$parsed" >> "$tmp_list"
        fi
    done < "$TARGETS_CONF"

    if _targets_write_atomic < "$tmp_list"; then
        rm -f "$tmp_list"
        log_info "target $package enabled=$state"
        return 0
    fi
    rm -f "$tmp_list"
    return 3
}

target_list() {
    [ -f "$TARGETS_CONF" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        parsed=$(_targets_parse_line "$line") || continue
        p=$(printf '%s' "$parsed" | cut -d'|' -f1)
        r=$(printf '%s' "$parsed" | cut -d'|' -f2)
        e=$(printf '%s' "$parsed" | cut -d'|' -f3)
        if [ "$e" = "1" ]; then
            printf '%s=%s\n' "$p" "$r"
        else
            printf '%s=%s (disabled)\n' "$p" "$r"
        fi
    done < "$TARGETS_CONF"
}

target_clear() {
    ensure_persistent_state
    : > "$TARGETS_CONF"
    chmod 644 "$TARGETS_CONF" 2>/dev/null
    _targets_sync_module
    log_info "all targets cleared"
    return 0
}

target_validate() {
    [ -f "$TARGETS_CONF" ] || return 0
    _targets_validate_file "$TARGETS_CONF"
}

