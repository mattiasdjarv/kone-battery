#!/usr/bin/env bash
# Remove the kone-battery scripts and (optionally) the systemd service
# and udev rule.

set -Eeuo pipefail
trap 'echo "Error on line $LINENO: $BASH_COMMAND" >&2' ERR

PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="$PREFIX/bin"
SERVICEDIR="$HOME/.config/systemd/user"
UDEV_FILE="/etc/udev/rules.d/99-kone-pro-air.rules"

SCRIPTS=(kone-daemon kone-status kone-notify)

# ── Flags ─────────────────────────────────────────────────────────────────────

AUTO_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
  -y | --yes) AUTO_YES=1 ;;
  -h | --help)
    echo "Usage: $(basename "$0") [-y|--yes]"
    echo "Removes kone-battery scripts, systemd service, and optionally the udev rule."
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    exit 1
    ;;
  esac
  shift
done

[[ -n "${NONINTERACTIVE:-}" ]] && AUTO_YES=1

# ── Output helpers ─────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  BOLD='\033[1m'
  GREEN='\033[32m'
  YELLOW='\033[33m'
  RED='\033[31m'
  BLUE='\033[34m'
  RESET='\033[0m'
else
  BOLD='' GREEN='' YELLOW='' RED='' BLUE='' RESET=''
fi

section() { printf "\n${BLUE}${BOLD}▶ %s${RESET}\n" "$1"; }
success() { printf "${GREEN}✓ %s${RESET}\n" "$*"; }
warn() { printf "${YELLOW}! %s${RESET}\n" "$*"; }
fail() { printf "${RED}✗ %s${RESET}\n" "$*"; }
info() { printf "  %s\n" "$*"; }

ask() {
  local prompt="$1"
  local default="${2:-N}"
  local choices
  if [[ "${default}" == "Y" ]]; then
    choices="Y/n"
  else
    choices="y/N"
  fi
  if ((AUTO_YES)); then return 0; fi
  if [[ ! -t 0 ]]; then
    # Non-interactive: fall back to the per-prompt default rather than always no.
    [[ "${default}" == "Y" ]] && return 0 || return 1
  fi
  read -r -p "$prompt [$choices] " ans
  case "${ans:-$default}" in
  [Yy]*) return 0 ;;
  *) return 1 ;;
  esac
}

# ── Summary state ─────────────────────────────────────────────────────────────

SUMMARY_SCRIPTS="- Nothing found"
SUMMARY_DAEMON="- Nothing found"
SUMMARY_UDEV="- Nothing found"

# ── Scripts ───────────────────────────────────────────────────────────────────

section "Scripts"
removed_scripts=0
for s in "${SCRIPTS[@]}"; do
  if [[ -f "$BINDIR/$s" ]]; then
    rm -f "$BINDIR/$s"
    success "$s removed from $BINDIR"
    ((removed_scripts++)) || true
  else
    warn "$s not found in $BINDIR"
  fi
done
if ((removed_scripts > 0)); then
  SUMMARY_SCRIPTS="✓ Removed $removed_scripts script(s)"
fi

# ── Systemd service ───────────────────────────────────────────────────────────

section "Background daemon"
if [[ -f "$SERVICEDIR/kone-daemon.service" ]]; then
  if ask "Remove the systemd user service?" Y; then
    systemctl --user disable --now kone-daemon.service 2>/dev/null || true
    rm -f "$SERVICEDIR/kone-daemon.service"
    systemctl --user daemon-reload
    success "Service removed"
    SUMMARY_DAEMON="✓ Removed"
  else
    warn "Systemd service kept"
    SUMMARY_DAEMON="- Kept (skipped)"
  fi
else
  warn "No systemd service found"
fi

# ── udev rule ─────────────────────────────────────────────────────────────────

section "udev rule"
if [[ -f "$UDEV_FILE" ]]; then
  if ask "Remove udev rule $UDEV_FILE?" N; then
    if [[ -w /etc/udev/rules.d ]]; then
      rm -f "$UDEV_FILE"
      udevadm control --reload-rules
      udevadm trigger
      success "udev rule removed"
      SUMMARY_UDEV="✓ Removed"
    else
      warn "Need root to remove $UDEV_FILE. Run manually:"
      info "  sudo rm $UDEV_FILE"
      info "  sudo udevadm control --reload-rules && sudo udevadm trigger"
      SUMMARY_UDEV="! Needs manual removal (see above)"
    fi
  else
    warn "udev rule kept"
    SUMMARY_UDEV="- Kept (skipped)"
  fi
else
  warn "No udev rule found"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

section "Done"

printf '\n'
printf "${BOLD}%-20s${RESET} %s\n" "Scripts" "$SUMMARY_SCRIPTS"
printf "${BOLD}%-20s${RESET} %s\n" "Daemon" "$SUMMARY_DAEMON"
printf "${BOLD}%-20s${RESET} %s\n" "udev rule" "$SUMMARY_UDEV"
