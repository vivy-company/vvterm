#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/build.sh"
SOURCE="$BUILD_DIR_SSH/libssh2-$LIBSSH2_COMMIT"
if [[ ! -f "$SOURCE/build-macos/src/libssh2_config.h" ]]; then
    echo 'Run scripts/build.sh ssh-engine (or ssh) before this native test.' >&2
    exit 1
fi
xcrun clang -DLIBSSH2_OPENSSL -DHAVE_CONFIG_H \
    -I"$SOURCE/include" -I"$SOURCE/src" -I"$SOURCE/build-macos/src" \
    -I"$ROOT/.build/ssh/openssl-macos/include" \
    "$ROOT/scripts/tests/libssh2_exit_status_test.c" \
    "$ROOT/Vendor/libssh2/macos/lib/libssh2.a" \
    "$ROOT/Vendor/libssh2/macos/lib/libcrypto.a" -lz \
    -o "$SOURCE/build-macos/vvterm-exit-status-test"
"$SOURCE/build-macos/vvterm-exit-status-test"
