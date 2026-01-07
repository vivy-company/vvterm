#!/bin/bash
set -euo pipefail

# Build libghostty as universal (arm64 + x86_64) static library with custom I/O support.
# Uses forked ghostty with callback backend for SSH clients.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/Vendor/libghostty"

# Use our forked ghostty with custom-io branch
GHOSTTY_REPO="https://github.com/wiedymi/ghostty"
GHOSTTY_BRANCH="custom-io"

# Bundle ID for VivyTerm (prevents loading user's Ghostty config)
BUNDLE_ID="app.vivy.VivyTerm"

REF="${1:-${GHOSTTY_BRANCH}}"

echo "Building libghostty @ ${REF} (custom-io fork)"

# Check dependencies
for cmd in git zig lipo; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: $cmd required (try 'brew install $cmd')" >&2
        exit 1
    fi
done

# Setup temp dir
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# Clone ghostty fork
echo "Cloning ghostty fork (custom-io branch)..."
git clone --filter=blob:none --branch "${GHOSTTY_BRANCH}" --depth 1 "${GHOSTTY_REPO}" "${WORKDIR}/ghostty"

cd "${WORKDIR}/ghostty"

# Patch build.zig to install libs on macOS (same as aizen)
perl -0pi -e 's/if \(!config\.target\.result\.os\.tag\.isDarwin\(\)\) \{/if (true) {/' "${WORKDIR}/ghostty/build.zig"

# Patch to link Metal frameworks (same as aizen)
if [ -f "${WORKDIR}/ghostty/pkg/macos/build.zig" ]; then
    perl -0pi -e 's/lib\.linkFramework\("IOSurface"\);/lib.linkFramework("IOSurface");\n    lib.linkFramework("Metal");\n    lib.linkFramework("MetalKit");/g' "${WORKDIR}/ghostty/pkg/macos/build.zig"
    perl -0pi -e 's/module\.linkFramework\("IOSurface", \.\{\}\);/module.linkFramework("IOSurface", .{});\n        module.linkFramework("Metal", .{});\n        module.linkFramework("MetalKit", .{});/g' "${WORKDIR}/ghostty/pkg/macos/build.zig"
fi

# Patch bundle ID to use VivyTerm's instead of Ghostty's
# This prevents loading user's Ghostty config from ~/Library/Application Support/com.mitchellh.ghostty/
sed -i '' "s/com\.mitchellh\.ghostty/${BUNDLE_ID}/g" "${WORKDIR}/ghostty/src/build_config.zig"

echo "Applied patches: bundle ID -> ${BUNDLE_ID}"

ZIG_FLAGS=(
    -Dapp-runtime=none
    -Demit-xcframework=false
    -Demit-macos-app=false
    -Demit-exe=false
    -Demit-docs=false
    -Demit-webdata=false
    -Demit-helpgen=false
    -Demit-terminfo=true
    -Demit-termcap=false
    -Demit-themes=false
    -Doptimize=ReleaseFast
    -Dstrip
)

build_arch() {
    local arch="$1"
    local outdir="${WORKDIR}/zig-out-${arch}"
    echo "Building for ${arch}..." >&2
    (cd "${WORKDIR}/ghostty" && zig build "${ZIG_FLAGS[@]}" -Dtarget="${arch}-macos" -p "${outdir}")
    if [ ! -f "${outdir}/lib/libghostty.a" ]; then
        echo "Error: build failed - ${outdir}/lib/libghostty.a not found" >&2
        exit 1
    fi
    echo "${outdir}/lib/libghostty.a"
}

ARM64_LIB="$(build_arch aarch64)"

# Copy arm64 binary (no universal needed for Apple Silicon only)
echo "Copying arm64 binary..."
mkdir -p "${VENDOR_DIR}/lib" "${VENDOR_DIR}/include"
cp "${ARM64_LIB}" "${VENDOR_DIR}/lib/libghostty.a"

# Copy headers (preserve module.modulemap which is custom)
if [ -d "${WORKDIR}/ghostty/include" ]; then
    rsync -a --exclude='module.modulemap' "${WORKDIR}/ghostty/include/" "${VENDOR_DIR}/include/"
fi

# Record version
cd "${WORKDIR}/ghostty"
printf "%s\n" "$(git rev-parse HEAD)" > "${VENDOR_DIR}/VERSION"

echo "Done: $(lipo -info "${VENDOR_DIR}/lib/libghostty.a")"
echo "Version: $(cat "${VENDOR_DIR}/VERSION")"
