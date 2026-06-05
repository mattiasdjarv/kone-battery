#!/usr/bin/env bash
# Kone Pro Air Battery Tools installer.
#
# The daemon must be running in the background for the other scripts to work:
# the mouse only sends battery packets on (re)connection, not continuously, so
# something has to be listening. A systemd user service is the recommended way
# to keep it running across logins, but a window-manager exec line or a
# ~/.config/autostart .desktop file works just as well.
#
# The bundled udev rule is a fallback. Modern systemd distros ship
# /lib/udev/rules.d/70-uaccess.rules, which already tags HID-class input
# devices (including the Kone Pro Air's interface) with uaccess, so the
# daemon can read /dev/hidrawN as the active local user. Only install this
# repo's rule if kone-daemon fails with EACCES on your system.

set -Eeuo pipefail
trap 'echo "Error on line $LINENO: $BASH_COMMAND" >&2' ERR

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-$HOME/.local}"
BINDIR="$PREFIX/bin"
SERVICEDIR="$HOME/.config/systemd/user"
UDEV_FILE="/etc/udev/rules.d/99-kone-pro-air.rules"

SCRIPTS=(kone-daemon kone-cli kone-bar kone-notify)

# ── Flags ────────────────────────────────────────────────────────────────────

AUTO_YES=0
SKIP_SYSTEMD=0
SKIP_UDEV=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Installs kone-daemon, kone-cli, kone-bar, and kone-notify to $BINDIR,
checks for the hidapi Python package, and optionally configures a systemd
user service and udev rule.

Options:
  -y, --yes           Answer yes to all prompts (non-interactive)
      --no-systemd    Skip the systemd service prompt
      --no-udev       Skip the udev rule prompt
  -h, --help          Show this help

Environment:
  NONINTERACTIVE=1    Same effect as --yes
  PREFIX              Install prefix (default: \$HOME/.local)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  -y | --yes) AUTO_YES=1 ;;
  --no-systemd) SKIP_SYSTEMD=1 ;;
  --no-udev) SKIP_UDEV=1 ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage
    exit 1
    ;;
  esac
  shift
done

[[ -n "${NONINTERACTIVE:-}" ]] && AUTO_YES=1

# ── Output helpers ────────────────────────────────────────────────────────────

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

# ── Summary state (populated as we go) ───────────────────────────────────────

SUMMARY_SCRIPTS="✓ Installed"
SUMMARY_HIDAPI="✓ Available"
SUMMARY_DAEMON="- Skipped"
SUMMARY_UDEV="- Skipped"

# ── Probe HID access ─────────────────────────────────────────────────────────
# Returns: "needed", "not_needed", or "unknown"
# Must be called after hidapi is confirmed installed.

check_udev_needed() {
  command -v python3 >/dev/null 2>&1 || {
    echo "unknown"
    return
  }
  python3 - <<'PY' 2>/dev/null || echo "unknown"
import hid, sys
try:
    found = False
    for d in hid.enumerate(0x1E7D, 0x2C8E):
        if d.get("usage_page") in (0xFF00, 0xFF01):
            found = True
            hid.device().open_path(d["path"])
    print("not_needed" if found else "unknown")
except OSError as e:
    if getattr(e, "errno", None) in (13, 1):
        print("needed")
    else:
        print("unknown")
except Exception:
    print("unknown")
PY
}

# ── hidapi install ────────────────────────────────────────────────────────────

install_hidapi() {
  if python3 -c "import hid" 2>/dev/null; then
    success "hidapi already installed"
    return 0
  fi

  local id=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    id="$ID"
  fi

  case "$id" in
  arch | manjaro | endeavouros | garuda | cachyos | arcolinux | artix | archcraft)
    warn "hidapi not importable. Install with pacman:"
    info "sudo pacman -S python-hidapi"
    info "(pip --user on Arch does not put packages on sys.path)"
    SUMMARY_HIDAPI="✗ Missing — run: sudo pacman -S python-hidapi"
    return 1
    ;;
  debian | ubuntu | pop | linuxmint | elementary | zorin)
    warn "hidapi not importable. Install with apt:"
    info "sudo apt install python3-hidapi"
    SUMMARY_HIDAPI="✗ Missing — run: sudo apt install python3-hidapi"
    return 1
    ;;
  fedora | nobara | rhel | centos | rocky | almalinux)
    warn "hidapi not importable. Install with dnf:"
    info "sudo dnf install python3-hidapi"
    SUMMARY_HIDAPI="✗ Missing — run: sudo dnf install python3-hidapi"
    return 1
    ;;
  *)
    info "Trying pip..."
    local pip_cmd=""
    if command -v pip >/dev/null 2>&1; then
      pip_cmd="pip install --user hidapi"
    elif command -v pip3 >/dev/null 2>&1; then
      pip_cmd="pip3 install --user hidapi"
    elif python3 -m pip --version >/dev/null 2>&1; then
      pip_cmd="python3 -m pip install --user hidapi"
    else
      warn "pip not found. Install hidapi manually: pip install hidapi"
      SUMMARY_HIDAPI="✗ Missing — install hidapi manually"
      return 1
    fi
    if $pip_cmd; then
      success "hidapi installed via pip"
    else
      warn "pip install failed: $pip_cmd"
      SUMMARY_HIDAPI="✗ Missing — pip install failed"
      return 1
    fi
    ;;
  esac
}

# ── Scripts ───────────────────────────────────────────────────────────────────

section "Scripts"
mkdir -p "$BINDIR"
for s in "${SCRIPTS[@]}"; do
  install -Dm755 "$HERE/$s" "$BINDIR/$s"
  success "$s -> $BINDIR/$s"
done

# ── hidapi ────────────────────────────────────────────────────────────────────

section "Python dependency (hidapi)"
install_hidapi || true # non-fatal; daemon will fail at runtime with a clear error

# ── Background daemon ─────────────────────────────────────────────────────────

section "Background daemon"

if ((SKIP_SYSTEMD)); then
  warn "Systemd service skipped (--no-systemd)"
elif ! command -v systemctl >/dev/null 2>&1 ||
  ! systemctl --user --version >/dev/null 2>&1; then
  warn "systemd user services unavailable on this system"
  info "Start the daemon manually via your WM autostart or a .desktop file"
elif ask "Set up a systemd user service so kone-daemon starts on login?" N; then
  mkdir -p "$SERVICEDIR"
  sed "s|%h/|$PREFIX/|" "$HERE/kone-daemon.service" >"$SERVICEDIR/kone-daemon.service"
  systemctl --user daemon-reload
  systemctl --user enable --now kone-daemon.service
  success "Service installed and started"
  info "Check status: systemctl --user status kone-daemon"
  SUMMARY_DAEMON="✓ Enabled (systemd)"
else
  warn "Systemd service skipped"
  info "The daemon must still run for the other scripts to work."
  info "Pick one of these to autostart it:"
  printf '\n'
  info "  GNOME     ~/.config/autostart/ .desktop, Exec=$BINDIR/kone-daemon"
  info "  Hyprland  exec-once = $BINDIR/kone-daemon"
  info "  i3/sway   exec $BINDIR/kone-daemon &"
  info "  Manual    kone-daemon &  (stops when the terminal closes)"
fi

# ── HID permissions ───────────────────────────────────────────────────────────
# Probe *after* hidapi install so the Python snippet has a chance to work.

section "HID permissions"

if ((SKIP_UDEV)); then
  warn "udev rule skipped (--no-udev)"
else
  udev_state=$(check_udev_needed)

  case "$udev_state" in
  needed)
    warn "Your user cannot read the Kone's HID node (EACCES) — rule is required"
    udev_default=Y
    udev_prompt="Install the udev rule now?"
    ;;
  not_needed)
    success "Your user can already read the Kone's HID node — rule not required"
    udev_default=N
    udev_prompt="Install the udev rule anyway?"
    ;;
  *)
    info "Could not probe HID access (mouse not connected, or hidapi missing)"
    udev_default=N
    udev_prompt="Install udev rule as a fallback?"
    ;;
  esac

  if ask "$udev_prompt" "$udev_default"; then
    if [[ -w /etc/udev/rules.d ]]; then
      cp "$HERE/99-kone-pro-air.rules" "$UDEV_FILE"
      udevadm control --reload-rules
      udevadm trigger
      success "udev rule installed — unplug and replug the dongle"
      SUMMARY_UDEV="✓ Installed"
    else
      warn "Need root for /etc/udev/rules.d. Run manually:"
      info "  sudo cp $HERE/99-kone-pro-air.rules $UDEV_FILE"
      info "  sudo udevadm control --reload-rules && sudo udevadm trigger"
      info "Then unplug and replug the dongle."
      SUMMARY_UDEV="! Needs manual install (see above)"
    fi
  else
    if [[ "$udev_state" == "needed" ]]; then
      fail "udev rule skipped, but it is required on this system"
      info "The daemon will fail with EACCES until you run:"
      info "  sudo cp $HERE/99-kone-pro-air.rules /etc/udev/rules.d/"
      info "  sudo udevadm control --reload-rules && sudo udevadm trigger"
      info "Then unplug and replug the dongle."
      SUMMARY_UDEV="✗ Skipped (EACCES — daemon will fail)"
    else
      warn "udev rule skipped"
      info "On most systemd distros, 70-uaccess.rules already covers this."
      info "If kone-daemon fails with 'Permission denied', rerun this script and answer Y."
    fi
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

section "Done"

printf '\n'
printf "${BOLD}%-20s${RESET} %s\n" "Scripts" "$SUMMARY_SCRIPTS"
printf "${BOLD}%-20s${RESET} %s\n" "hidapi" "$SUMMARY_HIDAPI"
printf "${BOLD}%-20s${RESET} %s\n" "Daemon" "$SUMMARY_DAEMON"
printf "${BOLD}%-20s${RESET} %s\n" "udev rule" "$SUMMARY_UDEV"

printf '\n'
info "Turn the mouse off and on, or unplug and replug the dongle to"
info "trigger the first battery packet. Then try:  kone-cli"
