#!/data/data/com.termux/files/usr/bin/bash
#
# uninstall.sh — remove the native Termux OpenCode installation.
#
# Removes:
#   - $PREFIX/bin/opencode
#   - $HOME/agents/opencode
#   - $HOME/opencode-local
#
# The final item contains OC Remote's local-server control scripts:
#   - $HOME/opencode-local/start.sh
#   - $HOME/opencode-local/stop.sh
#
# Leaves intact by default:
#   - Termux glibc runtime
#   - DNS resolver shim
#   - OpenCode config, providers, sessions, auth, and data
#

set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"

INSTALL_DIR="$HOME_DIR/agents/opencode"
LAUNCHER_LINK="$PREFIX/bin/opencode"

OC_REMOTE_DIR="$HOME_DIR/opencode-local"
OC_REMOTE_START="$OC_REMOTE_DIR/start.sh"
OC_REMOTE_STOP="$OC_REMOTE_DIR/stop.sh"

PORT="${OPENCODE_PORT:-4096}"

say() {
  printf '\u001B[1;36m[opencode-native]\u001B[0m %s
' "$*"
}

warn() {
  printf '\u001B[1;33m[opencode-native]\u001B[0m %s
' "$*" >&2
}

say "Stopping any OpenCode server using port $PORT..."

# This is deliberately best-effort. It should not fail the uninstall
# if no server is currently running.
pkill -TERM -f "opencode.*serve.*--port $PORT" 2>/dev/null || true

sleep 1

# If psmisc/fuser is present, use it as a final port-specific fallback.
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
fi

say "Removing normal OpenCode launcher..."

# Remove only the symlink/file used by this installer. Avoid deleting some
# unrelated future OpenCode installation if the target is no longer ours.
if [ -L "$LAUNCHER_LINK" ]; then
  target="$(readlink "$LAUNCHER_LINK" 2>/dev/null || true)"

  case "$target" in
    "$INSTALL_DIR/launcher.sh"|"$HOME_DIR/agents/opencode/launcher.sh")
      rm -f "$LAUNCHER_LINK"
      say "Removed: $LAUNCHER_LINK"
      ;;
    *)
      warn "Not removing $LAUNCHER_LINK because it does not point to this native installer:"
      warn "  $target"
      ;;
  esac
elif [ -e "$LAUNCHER_LINK" ]; then
  warn "Not removing $LAUNCHER_LINK because it is not a symlink."
  warn "It may belong to another OpenCode installation."
else
  say "No normal launcher symlink found."
fi

say "Removing native OpenCode install directory..."

if [ -d "$INSTALL_DIR" ]; then
  rm -rf -- "$INSTALL_DIR"
  say "Removed: $INSTALL_DIR"
else
  say "No native install directory found."
fi

say "Removing OC Remote local-server scripts..."

if [ -d "$OC_REMOTE_DIR" ]; then
  rm -rf -- "$OC_REMOTE_DIR"
  say "Removed: $OC_REMOTE_DIR"
else
  say "No OC Remote script directory found."
fi

echo
say "Native OpenCode installation removed."

say "Left intact:"
say "  - Termux glibc runtime: $PREFIX/glibc"
say "  - DNS resolver shim:   $PREFIX/lib/claude-resolvfix.so"
say "  - OpenCode config:     $HOME_DIR/.config/opencode"
say "  - OpenCode app data:   $HOME_DIR/.local/share/opencode"

echo
say "Optional full cleanup commands:"
say "  rm -rf -- "$HOME_DIR/.config/opencode""
say "  rm -rf -- "$HOME_DIR/.local/share/opencode""
say "  rm -f  -- "$PREFIX/lib/claude-resolvfix.so""
say "  pkg uninstall glibc patchelf-glibc binutils-glibc glibc-repo"