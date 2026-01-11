#!/bin/bash
set -euo pipefail

# Build libghostty for iOS (arm64) and iOS Simulator (arm64)
# Uses forked ghostty with callback backend for SSH clients.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/Vendor/libghostty"

# Use our forked ghostty with custom-io branch
GHOSTTY_REPO="https://github.com/wiedymi/ghostty"
GHOSTTY_BRANCH="custom-io"

# Bundle ID for VivyTerm (prevents loading user's Ghostty config)
BUNDLE_ID="app.vivy.VivyTerm"

REF="${1:-${GHOSTTY_BRANCH}}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

log_info "Building libghostty for iOS @ ${REF} (custom-io fork)"

# Check dependencies
for cmd in git zig lipo xcrun; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "$cmd required (try 'brew install $cmd')"
        exit 1
    fi
done

# Check Xcode SDK
IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)
SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null || true)

if [ -z "$IOS_SDK" ]; then
    log_error "iOS SDK not found. Install Xcode and run 'xcode-select --install'"
    exit 1
fi
if [ -z "$SIM_SDK" ]; then
    log_error "iOS Simulator SDK not found. Install Xcode and run 'xcode-select --install'"
    exit 1
fi

log_info "iOS SDK: $IOS_SDK"
log_info "Simulator SDK: $SIM_SDK"

# Setup temp dir (short path to avoid "File name too long")
WORKDIR="$(mktemp -d "/tmp/ghostty-ios.XXXXXX")"
# Use very short cache paths to avoid long archive member names.
export ZIG_GLOBAL_CACHE_DIR="/tmp/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="/tmp/zig-local-cache"
mkdir -p "${ZIG_GLOBAL_CACHE_DIR}" "${ZIG_LOCAL_CACHE_DIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

# Clone ghostty fork
log_info "Cloning ghostty fork (custom-io branch)..."
git clone --filter=blob:none --branch "${GHOSTTY_BRANCH}" --depth 1 "${GHOSTTY_REPO}" "${WORKDIR}/ghostty"

cd "${WORKDIR}/ghostty"

# Patch build.zig to install libs on iOS
log_info "Applying patches..."
perl -0pi -e 's/if \(!config\.target\.result\.os\.tag\.isDarwin\(\)\) \{/if (true) {/' "${WORKDIR}/ghostty/build.zig"

# Patch to link Metal frameworks
if [ -f "${WORKDIR}/ghostty/pkg/macos/build.zig" ]; then
    perl -0pi -e 's/lib\.linkFramework\("IOSurface"\);/lib.linkFramework("IOSurface");\n    lib.linkFramework("Metal");\n    lib.linkFramework("MetalKit");/g' "${WORKDIR}/ghostty/pkg/macos/build.zig"
    perl -0pi -e 's/module\.linkFramework\("IOSurface", \.\{\}\);/module.linkFramework("IOSurface", .{});\n        module.linkFramework("Metal", .{});\n        module.linkFramework("MetalKit", .{});/g' "${WORKDIR}/ghostty/pkg/macos/build.zig"
fi

# Patch IOSurfaceLayer to use CAIOSurfaceLayer on iOS (fixes garbled rendering)
if [ -f "${WORKDIR}/ghostty/src/renderer/metal/IOSurfaceLayer.zig" ]; then
    # Add builtin import
    perl -0pi -e 's/const std = @import\\(\"std\"\\);/const std = @import(\"std\");\\nconst builtin = @import(\"builtin\");/' "${WORKDIR}/ghostty/src/renderer/metal/IOSurfaceLayer.zig"
    # Prefer CAIOSurfaceLayer on iOS, fall back to CALayer otherwise
    perl -0pi -e 's/const CALayer =\\s*\\n\\s*objc\\.getClass\\(\"CALayer\"\\) orelse return error\\.ObjCFailed;/const base_layer = switch (comptime builtin\\.os\\.tag) {\\n        \\.ios => objc\\.getClass\\(\"CAIOSurfaceLayer\"\\) orelse\\n            objc\\.getClass\\(\"CALayer\"\\) orelse return error\\.ObjCFailed,\\n        else => objc\\.getClass\\(\"CALayer\"\\) orelse return error\\.ObjCFailed,\\n    };/' "${WORKDIR}/ghostty/src/renderer/metal/IOSurfaceLayer.zig"
    perl -0pi -e 's/objc\\.allocateClassPair\\(CALayer, \"IOSurfaceLayer\"\\)/objc.allocateClassPair(base_layer, \"IOSurfaceLayer\")/' "${WORKDIR}/ghostty/src/renderer/metal/IOSurfaceLayer.zig"
    # Make the layer opaque to avoid blending artifacts on iOS
    perl -0pi -e 's/layer\\.setProperty\\(\"contentsGravity\", macos\\.animation\\.kCAGravityTopLeft\\);/layer.setProperty(\"contentsGravity\", macos.animation.kCAGravityTopLeft);\\n    layer.setProperty(\"opaque\", true);/' "${WORKDIR}/ghostty/src/renderer/metal/IOSurfaceLayer.zig"
fi

# Patch bundle ID to use VivyTerm's
sed -i '' "s/com\.mitchellh\.ghostty/${BUNDLE_ID}/g" "${WORKDIR}/ghostty/src/build_config.zig"

log_info "Applied patches: bundle ID -> ${BUNDLE_ID}"

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

build_ios() {
    local outdir="${WORKDIR}/zig-out-ios"
    log_info "Building for iOS device (arm64)..."

    local sysroot_flag=()
    if [ -n "${IOS_SDK}" ]; then
        sysroot_flag=(--sysroot="${IOS_SDK}")
        export SDKROOT="${IOS_SDK}"
        export ZIG_SYSROOT="${IOS_SDK}"
        export CFLAGS="-isysroot ${IOS_SDK}"
        export CXXFLAGS="-isysroot ${IOS_SDK}"
        export LDFLAGS="-isysroot ${IOS_SDK}"
        export CPATH="${IOS_SDK}/usr/include"
        export CPLUS_INCLUDE_PATH="${IOS_SDK}/usr/include/c++/v1"
        export LIBRARY_PATH="${IOS_SDK}/usr/lib"
    fi

    (cd "${WORKDIR}/ghostty" && zig build "${ZIG_FLAGS[@]}" -Dtarget=aarch64-ios "${sysroot_flag[@]}" -p "${outdir}" 2>&1) || {
        log_warn "iOS build with sysroot failed, trying without..."
        unset SDKROOT
        (cd "${WORKDIR}/ghostty" && zig build "${ZIG_FLAGS[@]}" -Dtarget=aarch64-ios -p "${outdir}")
    }
    unset SDKROOT ZIG_SYSROOT CFLAGS CXXFLAGS LDFLAGS CPATH CPLUS_INCLUDE_PATH LIBRARY_PATH

    if [ ! -f "${outdir}/lib/libghostty.a" ]; then
        log_error "iOS build failed - ${outdir}/lib/libghostty.a not found"
        exit 1
    fi
    echo "${outdir}/lib/libghostty.a"
}

build_simulator() {
    local outdir="${WORKDIR}/zig-out-simulator"
    log_info "Building for iOS Simulator (arm64)..."

    local sysroot_flag=()
    if [ -n "${SIM_SDK}" ]; then
        sysroot_flag=(--sysroot="${SIM_SDK}")
        export SDKROOT="${SIM_SDK}"
        export ZIG_SYSROOT="${SIM_SDK}"
        export CFLAGS="-isysroot ${SIM_SDK}"
        export CXXFLAGS="-isysroot ${SIM_SDK}"
        export LDFLAGS="-isysroot ${SIM_SDK}"
        export CPATH="${SIM_SDK}/usr/include"
        export CPLUS_INCLUDE_PATH="${SIM_SDK}/usr/include/c++/v1"
        export LIBRARY_PATH="${SIM_SDK}/usr/lib"
    fi

    # Use the simulator target (not device) to ensure correct ABI.
    # We also pin a CPU model to avoid Zig's generic-aarch64 simulator issues.
    (cd "${WORKDIR}/ghostty" && zig build "${ZIG_FLAGS[@]}" -Dtarget=aarch64-ios-simulator -Dcpu=apple_a17 "${sysroot_flag[@]}" -p "${outdir}" 2>&1) || {
        log_warn "Simulator build with sysroot failed, trying without..."
        unset SDKROOT
        (cd "${WORKDIR}/ghostty" && zig build "${ZIG_FLAGS[@]}" -Dtarget=aarch64-ios-simulator -Dcpu=apple_a17 -p "${outdir}")
    }
    unset SDKROOT ZIG_SYSROOT CFLAGS CXXFLAGS LDFLAGS CPATH CPLUS_INCLUDE_PATH LIBRARY_PATH

    if [ ! -f "${outdir}/lib/libghostty.a" ]; then
        log_error "Simulator build failed - ${outdir}/lib/libghostty.a not found"
        exit 1
    fi
    echo "${outdir}/lib/libghostty.a"
}

# Build for iOS device
log_info "Building iOS device library..."
IOS_LIB="$(build_ios)"

# Build for iOS Simulator
log_info "Building iOS Simulator library..."
SIM_LIB="$(build_simulator)"

# Copy binaries
log_info "Copying binaries..."
mkdir -p "${VENDOR_DIR}/ios/lib" "${VENDOR_DIR}/ios/include"
mkdir -p "${VENDOR_DIR}/ios-simulator/lib" "${VENDOR_DIR}/ios-simulator/include"

cp "${IOS_LIB}" "${VENDOR_DIR}/ios/lib/libghostty.a"
cp "${SIM_LIB}" "${VENDOR_DIR}/ios-simulator/lib/libghostty.a"

# Copy headers (preserve module.modulemap which is custom)
if [ -d "${WORKDIR}/ghostty/include" ]; then
    rsync -a --exclude='module.modulemap' "${WORKDIR}/ghostty/include/" "${VENDOR_DIR}/ios/include/"
    rsync -a --exclude='module.modulemap' "${WORKDIR}/ghostty/include/" "${VENDOR_DIR}/ios-simulator/include/"
fi

# Create module map for iOS
create_modulemap() {
    local target_dir="$1"
    cat > "${target_dir}/include/module.modulemap" << 'EOF'
module ghostty [system] {
    header "ghostty.h"
    link "ghostty"
    export *
}
EOF
}

create_modulemap "${VENDOR_DIR}/ios"
create_modulemap "${VENDOR_DIR}/ios-simulator"

# Record version
cd "${WORKDIR}/ghostty"
printf "%s\n" "$(git rev-parse HEAD)" > "${VENDOR_DIR}/ios/VERSION"
printf "%s\n" "$(git rev-parse HEAD)" > "${VENDOR_DIR}/ios-simulator/VERSION"

log_info "======================================="
log_info "Build complete!"
log_info "iOS device: $(ls -lh "${VENDOR_DIR}/ios/lib/libghostty.a" | awk '{print $5}')"
log_info "iOS Simulator: $(ls -lh "${VENDOR_DIR}/ios-simulator/lib/libghostty.a" | awk '{print $5}')"
log_info "Version: $(cat "${VENDOR_DIR}/ios/VERSION")"
log_info "======================================="
