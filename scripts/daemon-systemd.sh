#!/usr/bin/env bash
# Manage agent-memory-daemon as a systemd user service (Linux).
# Usage: ./scripts/daemon-systemd.sh {start|stop|remove|status|check} [config-path]
# Env:
#   LOG_DIR       Override log directory (default: $HOME/.agent-memory/logs)
#   LOG_TTL_DAYS  Delete *.log older than N days on start (0 or unset = no cleanup)
#
# Exit codes: 0 ok, 1 usage/install error, 2 systemd user manager unreachable.
set -euo pipefail

UNIT="agent-memory-daemon.service"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_FILE="$UNIT_DIR/$UNIT"
LOG_DIR="${LOG_DIR:-$HOME/.agent-memory/logs}"
LOG_TTL_DAYS="${LOG_TTL_DAYS:-0}"
CONFIG="${2:-$HOME/.agent-memory/memconsolidate.toml}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/agent-memory-daemon.service.template"

cleanup_logs() {
    [[ "$LOG_TTL_DAYS" -gt 0 && -d "$LOG_DIR" ]] || return 0
    find "$LOG_DIR" -maxdepth 1 -name '*.log' -type f -mtime +"$LOG_TTL_DAYS" -delete 2>/dev/null || true
}

# Fail clearly when there is no reachable per-user systemd manager
# (containers, sandboxes, some SSH-only hosts).
require_user_manager() {
    command -v systemctl >/dev/null 2>&1 || { echo "error: systemctl not found; this host does not use systemd." >&2; exit 2; }
    if ! systemctl --user show-environment >/dev/null 2>&1; then
        echo "error: cannot reach the systemd user manager (systemctl --user failed)." >&2
        echo "  Common causes: no login session, XDG_RUNTIME_DIR unset, or user bus blocked by the host." >&2
        echo "  Fallback: run the daemon manually: agent-memory-daemon start \"$CONFIG\"" >&2
        exit 2
    fi
}

# User units only start at boot (before login) when lingering is enabled.
warn_linger() {
    local linger
    linger="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo unknown)"
    if [[ "$linger" != "yes" ]]; then
        echo "note: lingering is '$linger' for $USER — the daemon starts at login, not at boot."
        echo "  To start at boot, run: sudo loginctl enable-linger $USER"
    fi
}

install_unit() {
    local bin
    bin="$(command -v agent-memory-daemon || true)"
    [[ -z "$bin" ]] && { echo "error: agent-memory-daemon not found in PATH. Install with: npm i -g agent-memory-daemon" >&2; exit 1; }
    bin="$(readlink -f "$bin")"
    [[ ! -f "$CONFIG" ]] && { echo "error: config not found: $CONFIG" >&2; exit 1; }
    mkdir -p "$LOG_DIR" "$UNIT_DIR"
    # The daemon's bin is a `#!/usr/bin/env node` script, so node must be on the unit's PATH.
    # Prepend node's own dir in case it lives in a version manager (nvm, mise, asdf).
    local node_dir unit_path
    node_dir="$(dirname "$(readlink -f "$(command -v node)")")"
    unit_path="$node_dir:$PATH"
    sed -e "s|__DAEMON_BIN__|$bin|g" \
        -e "s|__CONFIG__|$CONFIG|g" \
        -e "s|__LOG_DIR__|$LOG_DIR|g" \
        -e "s|__PATH__|$unit_path|g" \
        -e "s|__HOME__|$HOME|g" \
        "$TEMPLATE" > "$UNIT_FILE"
}

case "${1:-}" in
    start)
        require_user_manager
        cleanup_logs
        install_unit
        systemctl --user daemon-reload
        systemctl --user enable "$UNIT" >/dev/null
        systemctl --user restart "$UNIT"
        echo "started. unit: $UNIT_FILE"
        echo "logs: $LOG_DIR/daemon.{out,err}.log"
        warn_linger
        ;;
    stop)
        require_user_manager
        [[ -f "$UNIT_FILE" ]] && systemctl --user stop "$UNIT" && echo "stopped." || echo "not installed."
        ;;
    remove)
        if systemctl --user show-environment >/dev/null 2>&1; then
            systemctl --user disable --now "$UNIT" 2>/dev/null || true
        fi
        rm -f "$UNIT_FILE"
        systemctl --user daemon-reload 2>/dev/null || true
        echo "removed $UNIT_FILE (config and data untouched)."
        ;;
    status)
        require_user_manager
        if systemctl --user is-active --quiet "$UNIT"; then
            systemctl --user show "$UNIT" -p MainPID -p ActiveState -p SubState --no-pager
        else
            echo "not running."
        fi
        ;;
    check)
        # Preflight only: exit 0 if a user manager is reachable, 2 otherwise.
        require_user_manager
        echo "systemd user manager reachable."
        warn_linger
        ;;
    *)
        echo "usage: $0 {start|stop|remove|status|check} [config-path]" >&2
        exit 1
        ;;
esac
