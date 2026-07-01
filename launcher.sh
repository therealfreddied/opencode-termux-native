#!/data/data/com.termux/files/usr/bin/bash
# opencode — native Termux launcher (OpenCode, glibc Bun binary). No proot.
#
# Like Claude's Bun binary: patchelf the interpreter to Termux's glibc loader and
# run it directly (0x10000-aligned + patchelf-clean, so no align-fix / loader-
# direct needed). The claude-resolvfix.so shim handles DNS (redirects
# /etc/resolv.conf) AND scrubs LD_PRELOAD/LD_LIBRARY_PATH so opencode's bionic
# child tools (bash, git, ripgrep) don't choke on glibc. Re-patchelfs after a
# self-update (which restores the /lib/ld-linux interpreter).
PREFIX="/data/data/com.termux/files/usr"
DIR="$HOME/agents/opencode"
BIN="$DIR/opencode"
GLD="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
PE="$PREFIX/glibc/bin/patchelf"
SHIM="$PREFIX/lib/claude-resolvfix.so"

[ -f "$BIN" ] || { echo "[opencode] binary not found at $BIN — reinstall." >&2; exit 1; }
[ "$(LD_PRELOAD= "$PE" --print-interpreter "$BIN" 2>/dev/null)" = "$GLD" ] || \
  LD_PRELOAD= "$PE" --set-interpreter "$GLD" "$BIN" 2>/dev/null
exec env LD_PRELOAD="$SHIM" LD_LIBRARY_PATH="$PREFIX/glibc/lib" \
     SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem" "$BIN" "$@"
