#!/bin/bash
# VivyTerm vendor build (GhosttyKit + libssh2/OpenSSL)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

VENDOR_GHOSTTY="$PROJECT_ROOT/Vendor/libghostty"
VENDOR_SSH="$PROJECT_ROOT/Vendor/libssh2"
BUILD_DIR_SSH="$PROJECT_ROOT/.build/ssh"

OPENSSL_VERSION="3.2.0"
LIBSSH2_VERSION="1.11.0"
MACOS_DEPLOYMENT_TARGET="13.3"
IOS_DEPLOYMENT_TARGET="16.0"

GHOSTTY_REPO="git@github.com:wiedymi/ghostty.git"
GHOSTTY_REF="${GHOSTTY_REF:-custom-io}"
BUNDLE_ID="app.vivy.VivyTerm"

KEEP_WORKDIR="${KEEP_WORKDIR:-0}"
GHOSTTY_WORKDIR=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "\n${BLUE}==== $1 ====${NC}\n"; }

print_usage() {
    cat << EOF
VivyTerm Build Script

Usage: $0 [command]

Commands:
  all       Build GhosttyKit + libssh2/OpenSSL (default)
  ghostty   Build GhosttyKit.xcframework and copy .a libs
  ssh       Build libssh2 + OpenSSL (macOS + iOS + simulator)
  clean     Remove .build + Vendor libraries
  help      Show this help message

Env:
  GHOSTTY_REF=<git-ref>   Build a specific ghostty ref (default: custom-io)
  KEEP_WORKDIR=1          Keep ghostty build temp dir for debugging
EOF
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log_error "Missing dependency: $1"
        exit 1
    fi
}

check_deps_ghostty() {
    require_cmd git
    require_cmd zig
    require_cmd xcodebuild
    require_cmd perl
    require_cmd rsync
}

check_deps_ssh() {
    require_cmd curl
    require_cmd tar
    require_cmd cmake
    require_cmd make
    require_cmd xcrun
}

strip_lib() {
    local lib="$1"
    if command -v xcrun >/dev/null 2>&1; then
        xcrun strip -S -x "$lib" || strip -S -x "$lib"
    else
        strip -S -x "$lib"
    fi
}

build_ghosttykit() {
    log_section "GhosttyKit"

    GHOSTTY_WORKDIR="$(mktemp -d "/tmp/ghosttykit.XXXXXX")"
    local workdir="$GHOSTTY_WORKDIR"

    log_info "Cloning ghostty @ ${GHOSTTY_REF}..."
    git clone --filter=blob:none --branch "${GHOSTTY_REF}" --depth 1 "${GHOSTTY_REPO}" "${workdir}/ghostty"

    # Patch to link Metal frameworks (same as aizen)
    if [ -f "${workdir}/ghostty/pkg/macos/build.zig" ]; then
        perl -0pi -e 's/lib\.linkFramework\("IOSurface"\);/lib.linkFramework("IOSurface");\n    lib.linkFramework("Metal");\n    lib.linkFramework("MetalKit");/g' "${workdir}/ghostty/pkg/macos/build.zig"
        perl -0pi -e 's/module\.linkFramework\("IOSurface", \.\{\}\);/module.linkFramework("IOSurface", .{});\n        module.linkFramework("Metal", .{});\n        module.linkFramework("MetalKit", .{});/g' "${workdir}/ghostty/pkg/macos/build.zig"
    fi

    # IOSurfaceLayer fixes live in the Ghostty fork; no local patching here.

    # Patch bundle ID to use VivyTerm's instead of Ghostty's
    sed -i '' "s/com\\.mitchellh\\.ghostty/${BUNDLE_ID}/g" "${workdir}/ghostty/src/build_config.zig"

    # Lower iOS minimum to match app deployment target
    perl -0pi -e 's@// iOS [0-9]+ picked arbitrarily@// iOS 16 matches app deployment target@' "${workdir}/ghostty/src/build/Config.zig"
    perl -0pi -e 's/\\.ios => \\.\\{ \\.semver = \\.\\{\\n\\s*\\.major = [0-9]+,\\n\\s*\\.minor = [0-9]+,\\n\\s*\\.patch = [0-9]+,\\n\\s*\\} \\},/\\.ios => .{ .semver = .{\\n            .major = 16,\\n            .minor = 0,\\n            .patch = 0,\\n        } },/s' "${workdir}/ghostty/src/build/Config.zig"

    log_info "Building GhosttyKit.xcframework..."

    local zig_flags=(
        -Dapp-runtime=none
        -Demit-xcframework=true
        -Demit-macos-app=false
        -Demit-exe=false
        -Demit-docs=false
        -Demit-webdata=false
        -Demit-helpgen=false
        -Demit-terminfo=false
        -Demit-termcap=false
        -Demit-themes=false
        -Doptimize=ReleaseFast
        -Dstrip
        -Dxcframework-target=universal
    )

    (cd "${workdir}/ghostty" && zig build "${zig_flags[@]}" -p "${workdir}/zig-out")

    local xcframework="${workdir}/ghostty/macos/GhosttyKit.xcframework"
    if [ ! -d "${xcframework}" ]; then
        log_error "${xcframework} not found"
        exit 1
    fi

    local macos_lib
    local ios_lib
    local sim_lib
    macos_lib=$(find "${xcframework}" -path "*/macos-*/libghostty*.a" -type f -print -quit)
    ios_lib=$(find "${xcframework}" -path "*/ios-arm64/libghostty*.a" -type f -print -quit)
    sim_lib=$(find "${xcframework}" -path "*/ios-arm64-simulator/libghostty*.a" -type f -print -quit)

    if [ -z "${macos_lib}" ] || [ -z "${ios_lib}" ] || [ -z "${sim_lib}" ]; then
        log_error "Failed to locate libghostty.a inside xcframework"
        exit 1
    fi

    mkdir -p "${VENDOR_GHOSTTY}/lib" "${VENDOR_GHOSTTY}/ios/lib" "${VENDOR_GHOSTTY}/ios-simulator/lib"
    cp "${macos_lib}" "${VENDOR_GHOSTTY}/lib/libghostty.a"
    cp "${ios_lib}" "${VENDOR_GHOSTTY}/ios/lib/libghostty.a"
    cp "${sim_lib}" "${VENDOR_GHOSTTY}/ios-simulator/lib/libghostty.a"

    if [ -d "${workdir}/ghostty/include" ]; then
        mkdir -p "${VENDOR_GHOSTTY}/include" "${VENDOR_GHOSTTY}/ios/include" "${VENDOR_GHOSTTY}/ios-simulator/include"
        rsync -a --exclude='module.modulemap' "${workdir}/ghostty/include/" "${VENDOR_GHOSTTY}/include/"
        rsync -a --exclude='module.modulemap' "${workdir}/ghostty/include/" "${VENDOR_GHOSTTY}/ios/include/"
        rsync -a --exclude='module.modulemap' "${workdir}/ghostty/include/" "${VENDOR_GHOSTTY}/ios-simulator/include/"
    fi

    rm -rf "${VENDOR_GHOSTTY}/GhosttyKit.xcframework"
    rsync -a "${xcframework}" "${VENDOR_GHOSTTY}/"

    printf "%s\n" "$(git -C "${workdir}/ghostty" rev-parse HEAD)" > "${VENDOR_GHOSTTY}/VERSION"

    strip_lib "${VENDOR_GHOSTTY}/lib/libghostty.a"
    strip_lib "${VENDOR_GHOSTTY}/ios/lib/libghostty.a"
    strip_lib "${VENDOR_GHOSTTY}/ios-simulator/lib/libghostty.a"

    # Also strip static libs inside the xcframework to stay under GitHub size limits.
    while IFS= read -r -d '' lib; do
        strip_lib "${lib}"
    done < <(find "${VENDOR_GHOSTTY}/GhosttyKit.xcframework" -name "*.a" -type f -print0)

    log_info "GhosttyKit done"
    log_info "  macOS: $(ls -lh "${VENDOR_GHOSTTY}/lib/libghostty.a" | awk '{print $5}')"
    log_info "  iOS: $(ls -lh "${VENDOR_GHOSTTY}/ios/lib/libghostty.a" | awk '{print $5}')"
    log_info "  iOS Simulator: $(ls -lh "${VENDOR_GHOSTTY}/ios-simulator/lib/libghostty.a" | awk '{print $5}')"

    if [ "${KEEP_WORKDIR}" = "1" ]; then
        log_warn "Keeping workdir: ${workdir}"
    else
        rm -rf "${workdir}"
        GHOSTTY_WORKDIR=""
    fi
}

# ---------- libssh2 / OpenSSL ----------

download_sources() {
    mkdir -p "${BUILD_DIR_SSH}"
    cd "${BUILD_DIR_SSH}"

    if [ ! -d "openssl-${OPENSSL_VERSION}" ]; then
        log_info "Downloading OpenSSL ${OPENSSL_VERSION}..."
        curl -L -O "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
        tar xzf "openssl-${OPENSSL_VERSION}.tar.gz"
    fi

    if [ ! -d "libssh2-${LIBSSH2_VERSION}" ]; then
        log_info "Downloading libssh2 ${LIBSSH2_VERSION}..."
        curl -L -O "https://www.libssh2.org/download/libssh2-${LIBSSH2_VERSION}.tar.gz"
        tar xzf "libssh2-${LIBSSH2_VERSION}.tar.gz"
    fi
}

build_openssl_macos() {
    log_info "Building OpenSSL for macOS arm64..."
    cd "${BUILD_DIR_SSH}/openssl-${OPENSSL_VERSION}"

    make clean 2>/dev/null || true

    local mac_sdk
    mac_sdk=$(xcrun --sdk macosx --show-sdk-path)
    export MACOSX_DEPLOYMENT_TARGET="${MACOS_DEPLOYMENT_TARGET}"
    export CC="$(xcrun --sdk macosx -f clang) -isysroot ${mac_sdk} -mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET}"

    ./Configure darwin64-arm64-cc \
        --prefix="${BUILD_DIR_SSH}/openssl-macos" \
        no-shared \
        no-tests

    make -j"$(sysctl -n hw.ncpu)"
    make install_sw

    unset MACOSX_DEPLOYMENT_TARGET CC
}

build_openssl_ios() {
    log_info "Building OpenSSL for iOS arm64..."
    cd "${BUILD_DIR_SSH}/openssl-${OPENSSL_VERSION}"

    make clean 2>/dev/null || true

    local ios_sdk
    ios_sdk=$(xcrun --sdk iphoneos --show-sdk-path)
    export CROSS_TOP="$(xcrun --sdk iphoneos --show-sdk-platform-path)/Developer"
    export CROSS_SDK="iPhoneOS.sdk"
    export CC="$(xcrun --sdk iphoneos -f clang) -isysroot ${ios_sdk} -miphoneos-version-min=${IOS_DEPLOYMENT_TARGET}"

    ./Configure ios64-xcrun \
        --prefix="${BUILD_DIR_SSH}/openssl-ios" \
        -miphoneos-version-min=${IOS_DEPLOYMENT_TARGET} \
        no-shared \
        no-tests \
        no-apps

    make -j"$(sysctl -n hw.ncpu)" build_libs
    make install_sw

    unset CROSS_TOP CROSS_SDK CC
}

build_openssl_simulator() {
    log_info "Building OpenSSL for iOS Simulator arm64..."
    cd "${BUILD_DIR_SSH}/openssl-${OPENSSL_VERSION}"

    make clean 2>/dev/null || true

    local sim_sdk
    sim_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
    export CROSS_TOP="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)/Developer"
    export CROSS_SDK="iPhoneSimulator.sdk"
    export CC="$(xcrun --sdk iphonesimulator -f clang) -isysroot ${sim_sdk} -arch arm64 -mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET}"

    ./Configure iossimulator-xcrun \
        --prefix="${BUILD_DIR_SSH}/openssl-simulator" \
        -mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET} \
        no-shared \
        no-tests \
        no-apps

    make -j"$(sysctl -n hw.ncpu)" build_libs
    make install_sw

    unset CROSS_TOP CROSS_SDK CC
}

build_libssh2_macos() {
    log_info "Building libssh2 for macOS arm64..."
    cd "${BUILD_DIR_SSH}/libssh2-${LIBSSH2_VERSION}"

    rm -rf build-macos
    mkdir -p build-macos && cd build-macos

    cmake .. \
        -Wno-dev \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_DEPLOYMENT_TARGET} \
        -DCMAKE_INSTALL_PREFIX="${VENDOR_SSH}/macos" \
        -DOPENSSL_ROOT_DIR="${BUILD_DIR_SSH}/openssl-macos" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF

    make -j"$(sysctl -n hw.ncpu)"
    make install

    cp "${BUILD_DIR_SSH}/openssl-macos/lib/libssl.a" "${VENDOR_SSH}/macos/lib/"
    cp "${BUILD_DIR_SSH}/openssl-macos/lib/libcrypto.a" "${VENDOR_SSH}/macos/lib/"
}

build_libssh2_ios() {
    log_info "Building libssh2 for iOS arm64..."
    cd "${BUILD_DIR_SSH}/libssh2-${LIBSSH2_VERSION}"

    rm -rf build-ios
    mkdir -p build-ios && cd build-ios

    local ios_sdk
    ios_sdk=$(xcrun --sdk iphoneos --show-sdk-path)

    cmake .. \
        -Wno-dev \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="${ios_sdk}" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_DEPLOYMENT_TARGET} \
        -DCMAKE_INSTALL_PREFIX="${VENDOR_SSH}/ios" \
        -DOPENSSL_ROOT_DIR="${BUILD_DIR_SSH}/openssl-ios" \
        -DOPENSSL_INCLUDE_DIR="${BUILD_DIR_SSH}/openssl-ios/include" \
        -DOPENSSL_CRYPTO_LIBRARY="${BUILD_DIR_SSH}/openssl-ios/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="${BUILD_DIR_SSH}/openssl-ios/lib/libssl.a" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF

    make -j"$(sysctl -n hw.ncpu)"
    make install

    cp "${BUILD_DIR_SSH}/openssl-ios/lib/libssl.a" "${VENDOR_SSH}/ios/lib/"
    cp "${BUILD_DIR_SSH}/openssl-ios/lib/libcrypto.a" "${VENDOR_SSH}/ios/lib/"
}

build_libssh2_simulator() {
    log_info "Building libssh2 for iOS Simulator arm64..."
    cd "${BUILD_DIR_SSH}/libssh2-${LIBSSH2_VERSION}"

    rm -rf build-simulator
    mkdir -p build-simulator && cd build-simulator

    local sim_sdk
    sim_sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)

    cmake .. \
        -Wno-dev \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="${sim_sdk}" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_DEPLOYMENT_TARGET} \
        -DCMAKE_INSTALL_PREFIX="${VENDOR_SSH}/ios-simulator" \
        -DOPENSSL_ROOT_DIR="${BUILD_DIR_SSH}/openssl-simulator" \
        -DOPENSSL_INCLUDE_DIR="${BUILD_DIR_SSH}/openssl-simulator/include" \
        -DOPENSSL_CRYPTO_LIBRARY="${BUILD_DIR_SSH}/openssl-simulator/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="${BUILD_DIR_SSH}/openssl-simulator/lib/libssl.a" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF

    make -j"$(sysctl -n hw.ncpu)"
    make install

    cp "${BUILD_DIR_SSH}/openssl-simulator/lib/libssl.a" "${VENDOR_SSH}/ios-simulator/lib/"
    cp "${BUILD_DIR_SSH}/openssl-simulator/lib/libcrypto.a" "${VENDOR_SSH}/ios-simulator/lib/"
}

create_modulemap() {
    log_info "Writing libssh2 module map..."

    cat > "${VENDOR_SSH}/module.modulemap" << 'EOF_MODULE'
module libssh2 {
    header "include/libssh2.h"
    header "include/libssh2_sftp.h"
    header "include/libssh2_publickey.h"
    link "ssh2"
    link "ssl"
    link "crypto"
    export *
}
EOF_MODULE
}

build_ssh() {
    log_section "libssh2 + OpenSSL"
    download_sources
    build_openssl_macos
    build_libssh2_macos
    build_openssl_ios
    build_libssh2_ios
    build_openssl_simulator
    build_libssh2_simulator
    create_modulemap

    log_info "libssh2 done"
    log_info "  macOS: $(ls -lh "${VENDOR_SSH}/macos/lib/libssh2.a" | awk '{print $5}')"
    log_info "  iOS: $(ls -lh "${VENDOR_SSH}/ios/lib/libssh2.a" | awk '{print $5}')"
    log_info "  iOS Simulator: $(ls -lh "${VENDOR_SSH}/ios-simulator/lib/libssh2.a" | awk '{print $5}')"
}

clean() {
    log_section "Clean"
    rm -rf "${PROJECT_ROOT}/.build"
    rm -rf "${VENDOR_GHOSTTY}"
    rm -rf "${VENDOR_SSH}"
    log_info "Clean complete"
}

COMMAND="${1:-all}"

case "${COMMAND}" in
    all)
        check_deps_ghostty
        check_deps_ssh
        build_ghosttykit
        build_ssh
        ;;
    ghostty)
        check_deps_ghostty
        build_ghosttykit
        ;;
    ssh)
        check_deps_ssh
        build_ssh
        ;;
    clean)
        clean
        ;;
    help|--help|-h)
        print_usage
        ;;
    *)
        log_error "Unknown command: ${COMMAND}"
        print_usage
        exit 1
        ;;
 esac
