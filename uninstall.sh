#!/data/data/com.termux/files/usr/bin/bash
#
# uninstall.sh — remove the native OpenCode launcher + install dir.
# Leaves glibc, the shared DNS shim, and your OpenCode config.
#
set -euo pipefail
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
say(){ printf '\033[1;36m[opencode-native]\033[0m %s\n' "$*"; }

say "Removing launcher symlink…"; rm -f "$PREFIX/bin/opencode"
say "Removing install dir ($HOME_DIR/agents/opencode)…"; rm -rf "$HOME_DIR/agents/opencode"
say "Left intact: glibc, the shared DNS shim, and your OpenCode config/auth."
say "To remove config too:  rm -rf ~/.local/share/opencode ~/.config/opencode"
