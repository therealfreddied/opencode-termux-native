#!/data/data/com.termux/files/usr/bin/bash
#
# install.sh — OpenCode CLI, native on Termux (aarch64). No proot, no root.
#
# OpenCode ships a glibc-dynamic Bun binary (same shape as Claude Code). It runs
# native once its interpreter is patchelf'd to Termux's glibc loader; DNS comes
# from an LD_PRELOAD shim that redirects /etc/resolv.conf.
#
set -euo pipefail
say(){ printf '\033[1;36m[opencode-native]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[opencode-native] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
GL="$PREFIX/glibc"
GLD="$GL/lib/ld-linux-aarch64.so.1"
SHIM="$PREFIX/lib/claude-resolvfix.so"
RESOLV="$PREFIX/etc/resolv.conf"
DIR="$HOME_DIR/agents/opencode"
REPO="anomalyco/opencode"
RAW="https://raw.githubusercontent.com/Thr45hx/opencode-termux-native/main"

[ -d "$PREFIX" ] || die "Not a Termux environment."
case "$(uname -m)" in aarch64|arm64) ;; *) die "arm64/aarch64 only (found $(uname -m)).";; esac

SRC="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
need=0; for f in launcher.sh fix_resolv.c; do [ -f "$SRC/$f" ] || need=1; done
if [ "$need" = 1 ]; then
  command -v curl >/dev/null || die "curl required to fetch sources."
  SRC="$(mktemp -d)"; say "Fetching source files…"
  for f in launcher.sh fix_resolv.c; do curl -fsSL "$RAW/$f" -o "$SRC/$f" || die "fetch $f failed"; done
fi

say "Installing base packages (clang curl tar ca-certificates)…"
pkg update -y >/dev/null 2>&1 || true
pkg install -y clang curl tar ca-certificates >/dev/null || die "pkg install failed."

if [ ! -f "$GLD" ] || [ ! -x "$GL/bin/patchelf" ] || [ ! -x "$GL/bin/ld" ]; then
  say "Enabling the Termux glibc repo + runtime…"
  pkg install -y glibc-repo >/dev/null || die "glibc-repo failed."
  pkg update -y >/dev/null 2>&1 || true
  pkg install -y glibc patchelf-glibc binutils-glibc >/dev/null || die "glibc install failed."
fi
[ -f "$GLD" ] || die "glibc loader missing: $GLD"

if [ ! -f "$SHIM" ]; then
  say "Building DNS shim (claude-resolvfix.so)…"
  b="$(mktemp -d)"; cp "$SRC/fix_resolv.c" "$b/"
  ( cd "$b"
    clang --target=aarch64-linux-gnu -fPIC -O2 -fno-stack-protector -c fix_resolv.c -o fix_resolv.o
    "$GL/bin/ld" -shared -o libclaude-resolvfix.so fix_resolv.o -L"$GL/lib" -l:libc.so.6 -l:libdl.so.2
  ) || { rm -rf "$b"; die "shim build failed."; }
  install -m644 "$b/libclaude-resolvfix.so" "$SHIM"; rm -rf "$b"
fi
if [ ! -s "$RESOLV" ] || ! grep -q '^nameserver' "$RESOLV" 2>/dev/null; then
  mkdir -p "$(dirname "$RESOLV")"; printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$RESOLV"
fi

mkdir -p "$DIR"
ver="${1:-}"
if [ -z "$ver" ]; then url="https://github.com/$REPO/releases/latest/download/opencode-linux-arm64.tar.gz"
else url="https://github.com/$REPO/releases/download/v${ver#v}/opencode-linux-arm64.tar.gz"; fi
say "Downloading OpenCode (glibc arm64)…"
t="$(mktemp -d)"
curl -fsSL "$url" -o "$t/o.tar.gz" || { rm -rf "$t"; die "download failed."; }
tar xzf "$t/o.tar.gz" -C "$t" || { rm -rf "$t"; die "extract failed."; }
oc="$(find "$t" -type f -name opencode | head -1)"
[ -n "$oc" ] || { rm -rf "$t"; die "opencode binary not in archive."; }
install -m755 "$oc" "$DIR/opencode"; rm -rf "$t"

"$GL/bin/patchelf" --set-interpreter "$GLD" "$DIR/opencode"
install -m755 "$SRC/launcher.sh" "$DIR/launcher.sh"
ln -sf "$DIR/launcher.sh" "$PREFIX/bin/opencode"

say "Verifying…"
if opencode --version >/dev/null 2>&1; then say "Installed OpenCode $(opencode --version 2>/dev/null | head -1) — native, no proot."; else say "Installed; run 'opencode'."; fi
echo
say "Auth:  opencode providers   (add API keys; free models + HuggingFace built in)"
say "Run:   opencode             (TUI)   |   opencode run \"...\"   (one-shot)"
