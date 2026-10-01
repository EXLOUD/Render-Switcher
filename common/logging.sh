#!/system/bin/sh
# Render Switcher – logging (uses state.sh prepare_log / append_log_line)

log_info() {
    append_log_line "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')] [INFO] $*"
}

log_warn() {
    append_log_line "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')] [WARN] $*"
}

log_error() {
    append_log_line "[$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '?')] [ERROR] $*"
}

# Alias used by some scripts
log() { log_info "$@"; }
