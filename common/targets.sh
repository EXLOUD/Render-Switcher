#!/system/bin/sh
# Render Switcher – Target Apps Manager (single source of truth)
# Format in targets.conf:
#   package=renderer
#   package=renderer:0   (disabled)
# Comments and blank lines are ignored by the parser AND preserved on rewrite.
# Lines the parser does not understand are left untouched as well.
# Writes are atomic (tmp file + mv).
#
# The parser is pure shell (no sed/cut/printf forks per line), so list/set/add
# stay fast even with hundreds of targets.

# Pure-shell trim. Result in $_TRIMMED.
_trim_into() {
    _TRIMMED=$1
    _TRIMMED=${_TRIMMED#"${_TRIMMED%%[![:space:]]*}"}
    _TRIMMED=${_TRIMMED%"${_TRIMMED##*[![:space:]]}"}
}

# Parse one targets.conf line without forking.
# Sets _P_PKG _P_REN _P_EN. Returns 1 for blank / comment / invalid lines.
_tp_parse() {
    _P_PKG=""
    _P_REN=""
    _P_EN=1
    _tp_l=${1%%#*}
    _trim_into "$_tp_l"
    _tp_l=$_TRIMMED
    [ -n "$_tp_l" ] || return 1
    case "$_tp_l" in
        *=*) ;;
        *) return 1 ;;
    esac

    _trim_into "${_tp_l%%=*}"
    _tp_pkg=$_TRIMMED
    _trim_into "${_tp_l#*=}"
    _tp_rest=$_TRIMMED

    is_valid_package "$_tp_pkg" || return 1

    case "$_tp_rest" in
        *:*)
            _trim_into "${_tp_rest%%:*}"
            _tp_ren=$_TRIMMED
            _trim_into "${_tp_rest#*:}"
            _tp_en=$_TRIMMED
            ;;
        *)
            _trim_into "$_tp_rest"
            _tp_ren=$_TRIMMED
            _tp_en=1
            ;;
    esac

    is_valid_renderer "$_tp_ren" || return 1
    case "$_tp_en" in
        0|false|no|off) _tp_en=0 ;;
        *) _tp_en=1 ;;
    esac

    _P_PKG=$_tp_pkg
    _P_REN=$_tp_ren
    _P_EN=$_tp_en
    return 0
}

# Find one package. Sets _P_*.  rc: 0 found, 1 invalid package, 2 not found.
_tp_lookup() {
    is_valid_package "$1" || return 1
    [ -f "$TARGETS_CONF" ] || return 2
    while IFS= read -r _lk_line || [ -n "$_lk_line" ]; do
        if _tp_parse "$_lk_line" && [ "$_P_PKG" = "$1" ]; then
            return 0
        fi
    done < "$TARGETS_CONF"
    return 2
}

# $1 = package, $2 = renderer, $3 = 1|0
_target_line() {
    if [ "$3" = "1" ]; then
        printf '%s=%s\n' "$1" "$2"
    else
        printf '%s=%s:0\n' "$1" "$2"
    fi
}

_targets_validate_file() {
    _vf_file="$1"
    [ -f "$_vf_file" ] || return 0
    while IFS= read -r _vf_line || [ -n "$_vf_line" ]; do
        _trim_into "${_vf_line%%#*}"
        [ -z "$_TRIMMED" ] && continue
        _tp_parse "$_vf_line" || return 1
    done < "$_vf_file"
    return 0
}

# Zygisk runs in a mount namespace where only the module tree is reliably visible.
# Keep a mirror next to the .so so preAppSpecialize can read targets.
_MODULE_TARGETS="/data/adb/modules/render_switcher/targets.conf"
_targets_sync_module() {
    # Mirror must always equal TARGETS_CONF, otherwise Zygisk (reads the mirror
    # first) keeps applying a renderer for an app that is no longer in the list.
    [ -d "${_MODULE_TARGETS%/*}" ] || return 0
    if [ -f "$TARGETS_CONF" ]; then
        # skip the write when nothing changed (every skiactl call syncs)
        cmp -s "$TARGETS_CONF" "$_MODULE_TARGETS" 2>/dev/null && return 0
        cp -f "$TARGETS_CONF" "$_MODULE_TARGETS" 2>/dev/null
        chmod 644 "$_MODULE_TARGETS" 2>/dev/null
    else
        rm -f "$_MODULE_TARGETS" 2>/dev/null
    fi
}

# Single-pass atomic edit. Every line that is not the edited package (comments,
# blanks, other targets, even lines we can't parse) is copied verbatim.
#   _targets_edit add    <pkg> <renderer>        add or replace (enabled)
#   _targets_edit set    <pkg> <renderer>        change renderer, keep enabled flag
#   _targets_edit en     <pkg> "" <1|0>          change enabled flag, keep renderer
#   _targets_edit remove <pkg>
# rc: 0 ok, 2 package not found (set/en), 3 write failure
_targets_edit() {
    _te_mode=$1
    _te_pkg=$2
    _te_ren=$3
    _te_en=$4

    ensure_persistent_state
    _te_tmp="${TARGETS_CONF}.tmp.$$"
    : > "$_te_tmp" 2>/dev/null || return 3

    _te_found=0
    if [ -f "$TARGETS_CONF" ]; then
        while IFS= read -r _te_line || [ -n "$_te_line" ]; do
            if _tp_parse "$_te_line" && [ "$_P_PKG" = "$_te_pkg" ]; then
                # duplicate entries of the same package collapse into one
                [ "$_te_found" = "1" ] && continue
                _te_found=1
                case "$_te_mode" in
                    remove) ;;
                    add) _target_line "$_te_pkg" "$_te_ren" 1 >> "$_te_tmp" ;;
                    set) _target_line "$_te_pkg" "$_te_ren" "$_P_EN" >> "$_te_tmp" ;;
                    en)  _target_line "$_te_pkg" "$_P_REN" "$_te_en" >> "$_te_tmp" ;;
                esac
                continue
            fi
            printf '%s\n' "$_te_line" >> "$_te_tmp"
        done < "$TARGETS_CONF"
    fi

    case "$_te_mode" in
        add)
            [ "$_te_found" = "1" ] || _target_line "$_te_pkg" "$_te_ren" 1 >> "$_te_tmp"
            ;;
        set|en)
            [ "$_te_found" = "1" ] || { rm -f "$_te_tmp"; return 2; }
            ;;
        remove)
            [ "$_te_found" = "1" ] || { rm -f "$_te_tmp"; return 0; }
            ;;
    esac

    chmod 644 "$_te_tmp" 2>/dev/null
    if ! mv -f "$_te_tmp" "$TARGETS_CONF"; then
        rm -f "$_te_tmp"
        log_error "targets write failed ($_te_mode $_te_pkg)"
        return 3
    fi
    _targets_sync_module
    return 0
}

target_exists() {
    _tp_lookup "$1"
}

target_get_renderer() {
    _tp_lookup "$1" || return $?
    printf '%s\n' "$_P_REN"
}

target_is_enabled() {
    _tp_lookup "$1" || return 1
    [ "$_P_EN" = "1" ]
}

target_add() {
    is_valid_package "$1" || { log_error "invalid package: $1"; return 1; }
    is_valid_renderer "$2" || { log_error "invalid renderer: $2"; return 1; }
    _targets_edit add "$1" "$2" || return $?
    log_info "target: $1 -> $2"
}

target_remove() {
    is_valid_package "$1" || return 1
    _targets_edit remove "$1" || return $?
    log_info "target removed: $1"
}

target_set_renderer() {
    is_valid_package "$1" || return 1
    is_valid_renderer "$2" || return 1
    _targets_edit set "$1" "$2" || return $?
    log_info "target: $1 -> $2"
}

target_set_enabled() {
    _ts_state="$2"
    case "$_ts_state" in
        1|true|yes|on) _ts_state=1 ;;
        0|false|no|off) _ts_state=0 ;;
        *) return 1 ;;
    esac
    is_valid_package "$1" || return 1
    _targets_edit en "$1" "" "$_ts_state" || return $?
    log_info "target $1 enabled=$_ts_state"
}

target_list() {
    [ -f "$TARGETS_CONF" ] || return 0
    while IFS= read -r _tl_line || [ -n "$_tl_line" ]; do
        _tp_parse "$_tl_line" || continue
        if [ "$_P_EN" = "1" ]; then
            printf '%s=%s\n' "$_P_PKG" "$_P_REN"
        else
            printf '%s=%s (disabled)\n' "$_P_PKG" "$_P_REN"
        fi
    done < "$TARGETS_CONF"
    return 0
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
