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
REPO="anomalyco/opencode"

[ -f "$BIN" ] || { echo "[opencode] binary not found at $BIN — reinstall." >&2; exit 1; }
[ "$(LD_PRELOAD= "$PE" --print-interpreter "$BIN" 2>/dev/null)" = "$GLD" ] || \
  LD_PRELOAD= "$PE" --set-interpreter "$GLD" "$BIN" 2>/dev/null

# --- Update interception -----------------------------------------------------
# opencode's built-in `upgrade` (default `curl` method) runs the UPSTREAM install
# script, which drops a fresh binary in ~/.opencode/bin with the stock
# /lib/ld-linux interpreter (unrunnable in Termux) AND prepends that dir to PATH
# in ~/.bashrc — so the next shell picks the broken copy. That is NOT an update
# of our native layout. Intercept `update`/`upgrade` here and do the update the
# native way instead: download the glibc arm64 release tarball straight into
# $DIR/opencode and re-patchelf. (Also set "autoupdate": false in opencode.jsonc
# so the TUI/background updater can't re-trigger the upstream path.)
if [ "${1:-}" = "update" ] || [ "${1:-}" = "upgrade" ]; then
  ver="${2:-}"; case "$ver" in -*) ver="";; esac
  command -v curl >/dev/null 2>&1 || { echo "[opencode] curl required to update." >&2; exit 1; }
  if [ -z "$ver" ]; then
    url="https://github.com/$REPO/releases/latest/download/opencode-linux-arm64.tar.gz"
  else
    url="https://github.com/$REPO/releases/download/v${ver#v}/opencode-linux-arm64.tar.gz"
  fi
  cur="$(env LD_PRELOAD="$SHIM" LD_LIBRARY_PATH="$PREFIX/glibc/lib" \
         SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem" "$BIN" --version 2>/dev/null | head -1)"
  echo "[opencode] updating (glibc arm64, native) — current: ${cur:-unknown}, target: ${ver:-latest}"
  t="$(mktemp -d)"
  curl -fL# "$url" -o "$t/o.tar.gz" || { rm -rf "$t"; echo "[opencode] download failed." >&2; exit 1; }
  tar xzf "$t/o.tar.gz" -C "$t"     || { rm -rf "$t"; echo "[opencode] extract failed." >&2; exit 1; }
  oc="$(find "$t" -type f -name opencode | head -1)"
  [ -n "$oc" ] || { rm -rf "$t"; echo "[opencode] opencode binary not in archive." >&2; exit 1; }
  install -m755 "$oc" "$BIN"; rm -rf "$t"
  LD_PRELOAD= "$PE" --set-interpreter "$GLD" "$BIN" 2>/dev/null
  new="$(env LD_PRELOAD="$SHIM" LD_LIBRARY_PATH="$PREFIX/glibc/lib" \
         SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem" "$BIN" --version 2>/dev/null | head -1)"
  echo "[opencode] updated → ${new:-unknown} (native, no proot)."
  exit 0
fi
# -----------------------------------------------------------------------------

exec env LD_PRELOAD="$SHIM" LD_LIBRARY_PATH="$PREFIX/glibc/lib" \
     SSL_CERT_FILE="$PREFIX/etc/tls/cert.pem" "$BIN" "$@"
