#!/data/data/com.termux/files/usr/bin/bash
#
# install.sh — OpenCode CLI, native on Termux (aarch64). No PRoot, no root.
#
# Installs the official Linux ARM64 glibc OpenCode binary, patches it to use
# the Termux glibc interpreter, injects a DNS resolver shim, and creates:
#
#   opencode
#   opencode update [VERSION]
#   opencode rollback
#
# Creates the OC Remote local-server control scripts:
#
#   $HOME/opencode-local/start.sh
#   $HOME/opencode-local/stop.sh
#
# OC Remote local server:
#
#   http://127.0.0.1:4096
#

set -euo pipefail

unset LD_PRELOAD

say() {
  printf '\u001B[1;36m[opencode-native]\u001B[0m %s
' "$*"
}

warn() {
  printf '\u001B[1;33m[opencode-native]\u001B[0m %s
' "$*" >&2
}

die() {
  printf '\u001B[1;31m[opencode-native] ERROR:\u001B[0m %s
' "$*" >&2
  exit 1
}

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"

GL="$PREFIX/glibc"
GLD="$GL/lib/ld-linux-aarch64.so.1"

SHIM="$PREFIX/lib/claude-resolvfix.so"
RESOLV="$PREFIX/etc/resolv.conf"

DIR="$HOME_DIR/agents/opencode"
BIN="$DIR/opencode"
LAUNCHER="$DIR/launcher.sh"

OC_REMOTE_DIR="$HOME_DIR/opencode-local"
OC_REMOTE_START="$OC_REMOTE_DIR/start.sh"
OC_REMOTE_STOP="$OC_REMOTE_DIR/stop.sh"

REPO="anomalyco/opencode"
ASSET="opencode-linux-arm64.tar.gz"

[ -d "$PREFIX" ] || die "Not a Termux environment."

case "$(uname -m)" in
  aarch64|arm64)
    ;;
  *)
    die "This installer supports ARM64/aarch64 only; found: $(uname -m)."
    ;;
esac

say "Installing base packages..."

pkg update -y >/dev/null 2>&1 || true

pkg install -y \
  clang \
  curl \
  tar \
  ca-certificates \
  psmisc \
  >/dev/null 2>&1 \
  || die "Termux package installation failed."

if [ ! -f "$GLD" ] || \
   [ ! -x "$GL/bin/patchelf" ] || \
   [ ! -x "$GL/bin/ld" ]; then

  say "Installing Termux glibc runtime and patching tools..."

  pkg install -y glibc-repo >/dev/null 2>&1 \
    || die "glibc-repo installation failed."

  pkg update -y >/dev/null 2>&1 || true

  pkg install -y \
    glibc \
    patchelf-glibc \
    binutils-glibc \
    >/dev/null 2>&1 \
    || die "glibc, patchelf-glibc, or binutils-glibc installation failed."
fi

[ -f "$GLD" ] \
  || die "Termux glibc loader is missing: $GLD"

[ -x "$GL/bin/patchelf" ] \
  || die "patchelf is missing: $GL/bin/patchelf"

[ -x "$GL/bin/ld" ] \
  || die "glibc linker is missing: $GL/bin/ld"

# ---------------------------------------------------------------------------
# Build DNS resolver shim
# ---------------------------------------------------------------------------

if [ ! -f "$SHIM" ]; then
  say "Building DNS resolver shim..."

  BUILD_DIR="$(mktemp -d)"
  trap 'rm -rf "$BUILD_DIR"' EXIT

  cat > "$BUILD_DIR/fix_resolv.c" <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>

static int (*orig_open)(const char *pathname, int flags, ...) = NULL;
static int (*orig_openat)(int dirfd, const char *pathname, int flags, ...) = NULL;
static int (*orig_execve)(const char *pathname, char *const argv[], char *const envp[]) = NULL;

static const char *redirect_path(const char *path) {
    if (path && strcmp(path, "/etc/resolv.conf") == 0) {
        return "/data/data/com.termux/files/usr/etc/resolv.conf";
    }
    return path;
}

int open(const char *pathname, int flags, ...) {
    if (!orig_open) {
        orig_open = dlsym(RTLD_NEXT, "open");
    }

    return orig_open(redirect_path(pathname), flags);
}

int openat(int dirfd, const char *pathname, int flags, ...) {
    if (!orig_openat) {
        orig_openat = dlsym(RTLD_NEXT, "openat");
    }

    return orig_openat(dirfd, redirect_path(pathname), flags);
}

int execve(
    const char *pathname,
    char *const argv[],
    char *const envp[]
) {
    if (!orig_execve) {
        orig_execve = dlsym(RTLD_NEXT, "execve");
    }

    unsetenv("LD_PRELOAD");

    return orig_execve(pathname, argv, envp);
}
EOF

  (
    cd "$BUILD_DIR"

    clang \
      --target=aarch64-linux-gnu \
      -fPIC \
      -O2 \
      -fno-stack-protector \
      -c fix_resolv.c \
      -o fix_resolv.o

    "$GL/bin/ld" \
      -shared \
      -o libclaude-resolvfix.so \
      fix_resolv.o \
      -L"$GL/lib" \
      -l:libc.so.6 \
      -l:libdl.so.2
  ) || die "DNS resolver shim build failed."

  install -m 644 "$BUILD_DIR/libclaude-resolvfix.so" "$SHIM"

  rm -rf "$BUILD_DIR"
  trap - EXIT
fi

# ---------------------------------------------------------------------------
# Termux resolver file
# ---------------------------------------------------------------------------

if [ ! -s "$RESOLV" ] || \
   ! grep -q '^nameserver' "$RESOLV" 2>/dev/null; then

  say "Creating Termux resolver configuration..."

  mkdir -p "$(dirname "$RESOLV")"

  cat > "$RESOLV" <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
fi

# ---------------------------------------------------------------------------
# OpenCode binary installation
# ---------------------------------------------------------------------------

download_install_opencode() {
  local requested_version="${1:-}"
  local url
  local temp_dir
  local extracted_binary
  local new_binary

  if [ -n "$requested_version" ]; then
    url="https://github.com/$REPO/releases/download/v${requested_version#v}/$ASSET"
  else
    url="https://github.com/$REPO/releases/latest/download/$ASSET"
  fi

  mkdir -p "$DIR"

  temp_dir="$(mktemp -d)"

  say "Downloading OpenCode glibc ARM64${requested_version:+ v${requested_version#v}}..."

  if ! curl -fL --retry 3 --retry-delay 2 \
    "$url" \
    -o "$temp_dir/opencode.tar.gz"; then

    rm -rf "$temp_dir"
    die "Download failed: $url"
  fi

  if ! tar -xzf "$temp_dir/opencode.tar.gz" -C "$temp_dir"; then
    rm -rf "$temp_dir"
    die "Failed to extract the OpenCode archive."
  fi

  extracted_binary="$(
    find "$temp_dir" -type f -name opencode -print -quit
  )"

  if [ -z "$extracted_binary" ]; then
    rm -rf "$temp_dir"
    die "No executable named 'opencode' was found in the downloaded archive."
  fi

  new_binary="$DIR/opencode.new"

  install -m 755 "$extracted_binary" "$new_binary"

  if ! "$GL/bin/patchelf" \
    --set-interpreter "$GLD" \
    "$new_binary"; then

    rm -f "$new_binary"
    rm -rf "$temp_dir"
    die "Failed to patch the OpenCode ELF interpreter."
  fi

  # Verify before replacing the active binary.
  if ! LD_PRELOAD="$SHIM" \
    "$new_binary" \
    --version \
    >/dev/null 2>&1; then

    rm -f "$new_binary"
    rm -rf "$temp_dir"

    die "Downloaded OpenCode binary could not start under Termux glibc. Existing installation was not changed."
  fi

  if [ -x "$BIN" ]; then
    cp -f "$BIN" "$DIR/opencode.previous"
  fi

  mv -f "$new_binary" "$BIN"
  rm -rf "$temp_dir"

  say "Installed OpenCode: $(LD_PRELOAD="$SHIM" "$BIN" --version | head -n 1)"
}

REQUESTED_VERSION="${1:-}"
download_install_opencode "$REQUESTED_VERSION"

# ---------------------------------------------------------------------------
# Normal OpenCode launcher
# ---------------------------------------------------------------------------

cat > "$LAUNCHER" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash

set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"

DIR="$HOME_DIR/agents/opencode"
BIN="$DIR/opencode"
PREVIOUS="$DIR/opencode.previous"
FAILED="$DIR/opencode.failed"

SHIM="$PREFIX/lib/claude-resolvfix.so"
GL="$PREFIX/glibc"
GLD="$GL/lib/ld-linux-aarch64.so.1"

REPO="anomalyco/opencode"
ASSET="opencode-linux-arm64.tar.gz"

say() {
  printf '\u001B[1;36m[opencode-native]\u001B[0m %s
' "$*"
}

die() {
  printf '\u001B[1;31m[opencode-native] ERROR:\u001B[0m %s
' "$*" >&2
  exit 1
}

update_opencode() {
  local requested_version="${1:-}"
  local url
  local temp_dir
  local extracted_binary
  local new_binary

  if [ -n "$requested_version" ]; then
    url="https://github.com/$REPO/releases/download/v${requested_version#v}/$ASSET"
  else
    url="https://github.com/$REPO/releases/latest/download/$ASSET"
  fi

  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT

  say "Downloading update${requested_version:+ v${requested_version#v}}..."

  curl -fL --retry 3 --retry-delay 2 \
    "$url" \
    -o "$temp_dir/opencode.tar.gz" \
    || die "Download failed: $url"

  tar -xzf "$temp_dir/opencode.tar.gz" -C "$temp_dir" \
    || die "Archive extraction failed."

  extracted_binary="$(
    find "$temp_dir" -type f -name opencode -print -quit
  )"

  [ -n "$extracted_binary" ] \
    || die "No executable named 'opencode' was found in the archive."

  new_binary="$DIR/opencode.new"

  install -m 755 "$extracted_binary" "$new_binary"

  "$GL/bin/patchelf" \
    --set-interpreter "$GLD" \
    "$new_binary" \
    || {
      rm -f "$new_binary"
      die "patchelf failed. Existing OpenCode was kept."
    }

  if ! LD_PRELOAD="$SHIM" \
    "$new_binary" \
    --version \
    >/dev/null 2>&1; then

    rm -f "$new_binary"
    die "New OpenCode build failed verification. Existing OpenCode was kept."
  fi

  if [ -x "$BIN" ]; then
    cp -f "$BIN" "$PREVIOUS"
  fi

  mv -f "$new_binary" "$BIN"

  say "Updated successfully: $(LD_PRELOAD="$SHIM" "$BIN" --version | head -n 1)"
}

rollback_opencode() {
  [ -x "$PREVIOUS" ] \
    || die "No rollback binary exists at: $PREVIOUS"

  if [ -x "$BIN" ]; then
    cp -f "$BIN" "$FAILED"
  fi

  mv -f "$PREVIOUS" "$BIN"

  say "Rolled back successfully: $(LD_PRELOAD="$SHIM" "$BIN" --version | head -n 1)"
}

case "${1:-}" in
  update|upgrade)
    shift
    update_opencode "${1:-}"
    exit 0
    ;;
  rollback)
    rollback_opencode
    exit 0
    ;;
esac

[ -x "$BIN" ] || die "OpenCode binary missing: $BIN"
[ -f "$SHIM" ] || die "DNS shim missing: $SHIM"

export LD_PRELOAD="$SHIM"

exec "$BIN" "$@"
EOF

chmod 755 "$LAUNCHER"
ln -sfn "$LAUNCHER" "$PREFIX/bin/opencode"

# ---------------------------------------------------------------------------
# OC Remote start/stop scripts
# ---------------------------------------------------------------------------

mkdir -p "$OC_REMOTE_DIR"

cat > "$OC_REMOTE_START" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash

set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
HOME_DIR="${HOME:-/data/data/com.termux/files/home}"

OPENCODE="$PREFIX/bin/opencode"
HOST="${OPENCODE_HOST:-127.0.0.1}"
PORT="${OPENCODE_PORT:-4096}"

if [ ! -x "$OPENCODE" ]; then
  echo "OpenCode launcher is missing or not executable: $OPENCODE" >&2
  exit 1
fi

export PATH="$PREFIX/bin:$HOME_DIR/.local/bin:$HOME_DIR/bin:$PATH"
export NO_PROXY="127.0.0.1,localhost,::1"
export no_proxy="$NO_PROXY"

exec "$OPENCODE" serve \
  --hostname "$HOST" \
  --port "$PORT"
EOF

chmod 755 "$OC_REMOTE_START"

cat > "$OC_REMOTE_STOP" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash

set -euo pipefail

PORT="${OPENCODE_PORT:-4096}"

# Ask only OpenCode server processes using this port to terminate.
pkill -TERM -f "opencode.*serve.*--port $PORT" 2>/dev/null || true

sleep 1

# Optional fallback if psmisc/fuser is installed.
if command -v fuser >/dev/null 2>&1; then
  fuser -k "${PORT}/tcp" 2>/dev/null || true
fi
EOF

chmod 755 "$OC_REMOTE_STOP"

# ---------------------------------------------------------------------------
# OpenCode configuration
# ---------------------------------------------------------------------------

CFG_DIR="$HOME_DIR/.config/opencode"
CFGJSONC="$CFG_DIR/opencode.jsonc"
CFGJSON="$CFG_DIR/opencode.json"

if [ ! -f "$CFGJSONC" ] && [ ! -f "$CFGJSON" ]; then
  mkdir -p "$CFG_DIR"

  cat > "$CFGJSONC" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "autoupdate": false
}
EOF

  say "Wrote $CFGJSONC."
elif ! grep -qs '"autoupdate"' "$CFGJSONC" "$CFGJSON" 2>/dev/null; then
  warn 'TIP: add "autoupdate": false to your OpenCode config.'
fi

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

say "Verifying normal OpenCode launcher..."

if opencode --version >/dev/null 2>&1; then
  say "OpenCode installed: $(opencode --version | head -n 1)"
else
  die "OpenCode installed but failed version verification."
fi

say "Verifying OC Remote scripts..."

[ -x "$OC_REMOTE_START" ] \
  || die "OC Remote start script was not created: $OC_REMOTE_START"

[ -x "$OC_REMOTE_STOP" ] \
  || die "OC Remote stop script was not created: $OC_REMOTE_STOP"

say "OC Remote start script: $OC_REMOTE_START"
say "OC Remote stop script:  $OC_REMOTE_STOP"

echo
say "Run TUI:      opencode"
say 'Run one-shot: opencode run "your prompt"'
say "Update:       opencode update"
say "Pin version:  opencode update 1.18.31"
say "Rollback:     opencode rollback"
say "OC Remote:    Toggle Local Server"
say "Server URL:   http://127.0.0.1:4096"