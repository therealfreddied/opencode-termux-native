#!/data/data/com.termux/files/usr/bin/bash
#
# install.sh — OpenCode CLI, native on Termux (aarch64). No proot, no root.
# Self-contained: embeds fix_resolv.c and launcher.sh directly.
#

set -euo pipefail

# 1. Clear Termux's libtermux-exec hook so clang and glibc ld don't crash
unset LD_PRELOAD

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

[ -d "$PREFIX" ] || die "Not a Termux environment."

case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "arm64/aarch64 only (found $(uname -m)).";;
esac

say "Installing base packages (clang curl tar ca-certificates)…"
pkg update -y >/dev/null 2>&1 || true
pkg install -y clang curl tar ca-certificates >/dev/null 2>&1 || die "pkg install failed."

if [ ! -f "$GLD" ] || [ ! -x "$GL/bin/patchelf" ] || [ ! -x "$GL/bin/ld" ]; then
  say "Enabling the Termux glibc repo + runtime…"
  pkg install -y glibc-repo >/dev/null 2>&1 || die "glibc-repo failed."
pkg update -y >/dev/null 2>&1 || true
pkg install -y glibc patchelf-glibc binutils-glibc >/dev/null 2>&1 || die "glibc install failed."
fi

[ -f "$GLD" ] || die "glibc loader missing: $GLD"

# Build DNS shim (inlined directly, no external download needed)
if [ ! -f "$SHIM" ]; then
  say "Building DNS shim (claude-resolvfix.so)…"
  b="$(mktemp -d)"
  cat << 'EOF' > "$b/fix_resolv.c"
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>

static int (*orig_open)(const char *pathname, int flags, ...) = NULL;
static int (*orig_openat)(int dirfd, const char *pathname, int flags, ...) = NULL;
static int (*orig_execve)(const char *pathname, char *const argv[], char *const envp[]) = NULL;

static const char *redirect(const char *path) {
    if (path && strcmp(path, "/etc/resolv.conf") == 0) {
        return "/data/data/com.termux/files/usr/etc/resolv.conf";
    }
    return path;
}

int open(const char *pathname, int flags, ...) {
    if (!orig_open) orig_open = dlsym(RTLD_NEXT, "open");
    return orig_open(redirect(pathname), flags);
}

int openat(int dirfd, const char *pathname, int flags, ...) {
    if (!orig_openat) orig_openat = dlsym(RTLD_NEXT, "openat");
    return orig_openat(dirfd, redirect(pathname), flags);
}

int execve(const char *pathname, char *const argv[], char *const envp[]) {
    if (!orig_execve) orig_execve = dlsym(RTLD_NEXT, "execve");
    unsetenv("LD_PRELOAD");
    return orig_execve(pathname, argv, envp);
}
EOF

  (
    cd "$b"
    clang --target=aarch64-linux-gnu -fPIC -O2 -fno-stack-protector -c fix_resolv.c -o fix_resolv.o
    "$GL/bin/ld" -shared -o libclaude-resolvfix.so fix_resolv.o -L"$GL/lib" -l:libc.so.6 -l:libdl.so.2
  ) || { rm -rf "$b"; die "shim build failed."; }
  install -m644 "$b/libclaude-resolvfix.so" "$SHIM"
  rm -rf "$b"
fi

if [ ! -s "$RESOLV" ] || ! grep -q '^nameserver' "$RESOLV" 2>/dev/null; then
  mkdir -p "$(dirname "$RESOLV")"
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$RESOLV"
fi

mkdir -p "$DIR"
ver="${1:-}"
if [ -z "$ver" ]; then
  url="https://github.com/$REPO/releases/latest/download/opencode-linux-arm64.tar.gz"
else
  url="https://github.com/$REPO/releases/download/v${ver#v}/opencode-linux-arm64.tar.gz"
fi

say "Downloading OpenCode (glibc arm64)…"
t="$(mktemp -d)"
curl -fsSL "$url" -o "$t/o.tar.gz" || { rm -rf "$t"; die "download failed."; }
tar xzf "$t/o.tar.gz" -C "$t" || { rm -rf "$t"; die "extract failed."; }

oc="$(find "$t" -type f -name opencode | head -1)"
[ -n "$oc" ] || { rm -rf "$t"; die "opencode binary not in archive."; }

install -m755 "$oc" "$DIR/opencode"
rm -rf "$t"

"$GL/bin/patchelf" --set-interpreter "$GLD" "$DIR/opencode"

# Write the launcher directly (inlined, no external download needed)
cat << 'EOF' > "$DIR/launcher.sh"
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
DIR="$HOME_DIR/agents/opencode"
SHIM="$PREFIX/lib/claude-resolvfix.so"
GL="$PREFIX/glibc"
GLD="$GL/lib/ld-linux-aarch64.so.1"
REPO="anomalyco/opencode"

if [ "${1:-}" = "update" ] || [ "${1:-}" = "upgrade" ]; then
  shift
  ver="${1:-}"
  if [ -z "$ver" ]; then
    url="https://github.com/$REPO/releases/latest/download/opencode-linux-arm64.tar.gz"
  else
    url="https://github.com/$REPO/releases/download/v${ver#v}/opencode-linux-arm64.tar.gz"
  fi
  printf '\033[1;36m[opencode-native]\033[0m Updating OpenCode...\n'
  t="$(mktemp -d)"
  curl -fsSL "$url" -o "$t/o.tar.gz"
  tar xzf "$t/o.tar.gz" -C "$t"
  oc="$(find "$t" -type f -name opencode | head -1)"
  install -m755 "$oc" "$DIR/opencode"
  rm -rf "$t"
  "$GL/bin/patchelf" --set-interpreter "$GLD" "$DIR/opencode"
  printf '\033[1;32m[opencode-native]\033[0m Updated successfully!\n'
  exit 0
fi

export LD_PRELOAD="$SHIM"
exec "$DIR/opencode" "$@"
EOF

chmod 755 "$DIR/launcher.sh"
ln -sf "$DIR/launcher.sh" "$PREFIX/bin/opencode"

CFG_DIR="$HOME_DIR/.config/opencode"
CFGJSONC="$CFG_DIR/opencode.jsonc"
CFGJSON="$CFG_DIR/opencode.json"

if [ ! -f "$CFGJSONC" ] && [ ! -f "$CFGJSON" ]; then
  mkdir -p "$CFG_DIR"
  cat > "$CFGJSONC" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": false
}
JSON
  say "Wrote $CFGJSONC (autoupdate disabled — update with 'opencode update')."
elif ! grep -qs '"autoupdate"' "$CFGJSONC" "$CFGJSON" 2>/dev/null; then
  say "TIP: add \"autoupdate\": false to your opencode config; update with 'opencode update'."
fi

say "Verifying…"
if opencode --version >/dev/null 2>&1; then
  say "Installed OpenCode $(opencode --version 2>/dev/null | head -1) — native, no proot."
else
  say "Installed; run 'opencode'."
fi

echo
say "Auth:   opencode providers (add API keys; free models + HuggingFace built in)"
say "Run:    opencode (TUI) | opencode run \"...\" (one-shot)"
say "Update: opencode update (native re-download + patchelf; never use upstream 'upgrade')"
