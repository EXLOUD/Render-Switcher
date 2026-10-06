#!/system/bin/sh
# Render Switcher – utilities, validation, locks

has_cmd() { command -v "$1" >/dev/null 2>&1; }

prop_get() {
    if has_cmd resetprop; then
        resetprop "$1" 2>/dev/null
    elif has_cmd getprop; then
        getprop "$1" 2>/dev/null
    else
        return 4
    fi
}

prop_set() {
    # Only allow known safe property keys from callers; still fail-closed on empty
    [ -n "$1" ] || return 1
    if has_cmd resetprop; then
        resetprop "$1" "$2" 2>/dev/null
    elif has_cmd setprop; then
        setprop "$1" "$2" 2>/dev/null
    else
        return 4
    fi
}

# Android-style package name:
#   segment = [A-Za-z][A-Za-z0-9_]*
#   package = segment ('.' segment)+
# (>= 2 segments on purpose: zygisk/src/main.cpp validPackage() requires the same,
#  so skiactl must not accept names the Zygisk side would silently ignore)
# Rejects: empty, path traversal, consecutive dots, leading/trailing dots,
#          shell metacharacters, overly long names.
is_valid_package() {
    # Use _ivp_* names only — never clobber caller vars (rest, package, …)
    _ivp_pkg=$1
    [ -n "$_ivp_pkg" ] || return 1
    [ "${#_ivp_pkg}" -le 255 ] || return 1

    case "$_ivp_pkg" in
        *..*|.*|*.) return 1 ;;
        *[!A-Za-z0-9._]*) return 1 ;;
        *.*) ;;
        *) return 1 ;;
    esac

    _ivp_rest=$_ivp_pkg
    _ivp_segs=0
    while [ -n "$_ivp_rest" ]; do
        case "$_ivp_rest" in
            *.*)
                _ivp_seg=${_ivp_rest%%.*}
                _ivp_rest=${_ivp_rest#*.}
                ;;
            *)
                _ivp_seg=$_ivp_rest
                _ivp_rest=
                ;;
        esac
        _ivp_segs=$((_ivp_segs + 1))
        case "$_ivp_seg" in
            ''|[!A-Za-z]*|*[!A-Za-z0-9_]*) return 1 ;;
        esac
    done
    [ "$_ivp_segs" -ge 2 ] || return 1
    return 0
}

is_valid_renderer() {
    case "$1" in
        skiavk|skiagl) return 0 ;;
        *) return 1 ;;
    esac
}

trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

list_installed_packages() {
    filter="${1:-user}"
    has_cmd pm || return 4
    case "$filter" in
        user)   pm list packages -3 2>/dev/null | sed 's/^package://' ;;
        system) pm list packages -s 2>/dev/null | sed 's/^package://' ;;
        all)    pm list packages 2>/dev/null | sed 's/^package://' ;;
        *) return 1 ;;
    esac
}

# mkdir-based lock with stale-lock cleanup.
#  - owner PID dead            -> stale, removed immediately
#  - no/empty pid file for 2 s -> owner died between mkdir and writing the pid
acquire_lock() {
    name="$1"
    timeout="${2:-10}"
    # only allow simple lock names (no path injection)
    case "$name" in
        ''|*[!A-Za-z0-9_-]*) return 1 ;;
    esac
    lockpath="${LOCK_DIR}/${name}.lock"
    mkdir -p "$LOCK_DIR" 2>/dev/null
    i=0
    nopid=0
    while [ "$i" -lt "$timeout" ]; do
        if mkdir "$lockpath" 2>/dev/null; then
            echo "$$" > "${lockpath}/pid"
            return 0
        fi
        old=""
        [ -f "${lockpath}/pid" ] && old=$(cat "${lockpath}/pid" 2>/dev/null)
        if [ -n "$old" ]; then
            nopid=0
            if ! kill -0 "$old" 2>/dev/null; then
                rm -rf "$lockpath" 2>/dev/null
                continue
            fi
        else
            nopid=$((nopid + 1))
            if [ "$nopid" -ge 3 ]; then
                rm -rf "$lockpath" 2>/dev/null
                nopid=0
                continue
            fi
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

release_lock() {
    case "$1" in
        ''|*[!A-Za-z0-9_-]*) return 1 ;;
    esac
    rm -rf "${LOCK_DIR}/${1}.lock" 2>/dev/null
}
