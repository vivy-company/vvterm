#!/bin/bash
# VVTerm vendor build (GhosttyKit + libssh2/OpenSSL)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

VENDOR_GHOSTTY="$PROJECT_ROOT/Vendor/libghostty"
VENDOR_SSH="$PROJECT_ROOT/Vendor/libssh2"
BUILD_DIR_SSH="$PROJECT_ROOT/.build/ssh"

OPENSSL_VERSION="3.2.0"
OPENSSL_SHA256="14c826f07c7e433706fb5c69fa9e25dab95684844b4c962a2cf1bf183eb4690e"
LIBSSH2_VERSION="1.11.1"
LIBSSH2_SHA256="d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7"
MACOS_DEPLOYMENT_TARGET="13.3"
IOS_DEPLOYMENT_TARGET="16.0"

GHOSTTY_REPO="https://github.com/wiedymi/ghostty.git"
GHOSTTY_COMMIT="${GHOSTTY_COMMIT:-268a0a9d761fb19673f05d28042488e2002300f2}"
BUNDLE_ID="app.vivy.VivyTerm"
NATIVE_ARTIFACT_MANIFEST="$PROJECT_ROOT/Vendor/native-artifacts.sha256"

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
VVTerm Build Script

Usage: $0 [command]

Commands:
  all       Build GhosttyKit + libssh2/OpenSSL (default)
  ghostty   Build GhosttyKit.xcframework and copy .a libs
  ssh       Build libssh2 + OpenSSL (macOS + iOS + simulator)
  verify    Verify pinned sources and committed native artifact hashes
  clean     Remove .build + Vendor libraries
  help      Show this help message

Env:
  GHOSTTY_COMMIT=<sha>    Build a specific full ghostty commit SHA
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
    require_cmd rsync
    require_cmd xcrun
    require_cmd shasum
}

validate_sha256() {
    local value="$1"
    [[ "${value}" =~ ^[0-9a-f]{64}$ ]]
}

validate_git_commit() {
    local value="$1"
    [[ "${value}" =~ ^[0-9a-f]{40}$ ]]
}

verify_sha256() {
    local path="$1"
    local expected="$2"
    local actual

    validate_sha256 "${expected}" || {
        log_error "Invalid pinned SHA-256 value for ${path}"
        return 1
    }
    actual="$(shasum -a 256 "${path}" | awk '{print $1}')"
    if [ "${actual}" != "${expected}" ]; then
        log_error "SHA-256 verification failed for ${path}"
        return 1
    fi
}

download_verified_archive() {
    local url="$1"
    local destination="$2"
    local expected_sha256="$3"
    local partial="${destination}.download"

    if [ -f "${destination}" ] && verify_sha256 "${destination}" "${expected_sha256}"; then
        return
    fi

    curl --fail --location --proto '=https' --tlsv1.2 \
        --output "${partial}" \
        "${url}"
    verify_sha256 "${partial}" "${expected_sha256}"
    mv -f "${partial}" "${destination}"
}

write_native_artifact_manifest() {
    (
        cd "${PROJECT_ROOT}"
        find Vendor -type f -name '*.a' -print0 \
            | sort -z \
            | xargs -0 shasum -a 256 \
            > "${NATIVE_ARTIFACT_MANIFEST}"
    )
}

verify_native_sources() {
    validate_git_commit "${GHOSTTY_COMMIT}" || {
        log_error "GHOSTTY_COMMIT must be a full 40-character lowercase commit SHA"
        return 1
    }
    validate_sha256 "${OPENSSL_SHA256}" || return 1
    validate_sha256 "${LIBSSH2_SHA256}" || return 1

    local vendored_ghostty_commit
    vendored_ghostty_commit="$(tr -d '[:space:]' < "${VENDOR_GHOSTTY}/VERSION")"
    if [ "${vendored_ghostty_commit}" != "${GHOSTTY_COMMIT}" ]; then
        log_error "Vendored Ghostty does not match GHOSTTY_COMMIT"
        return 1
    fi

    (
        cd "${PROJECT_ROOT}"
        shasum -a 256 --check "${NATIVE_ARTIFACT_MANIFEST}"
    )
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

    validate_git_commit "${GHOSTTY_COMMIT}" || {
        log_error "GHOSTTY_COMMIT must be a full 40-character lowercase commit SHA"
        return 1
    }
    log_info "Fetching ghostty @ ${GHOSTTY_COMMIT}..."
    git init -q "${workdir}/ghostty"
    git -C "${workdir}/ghostty" remote add origin "${GHOSTTY_REPO}"
    GIT_TERMINAL_PROMPT=0 git -C "${workdir}/ghostty" fetch --depth 1 origin "${GHOSTTY_COMMIT}"
    git -C "${workdir}/ghostty" checkout -q --detach FETCH_HEAD
    local resolved_ghostty_commit
    resolved_ghostty_commit="$(git -C "${workdir}/ghostty" rev-parse HEAD)"
    if [ "${resolved_ghostty_commit}" != "${GHOSTTY_COMMIT}" ]; then
        log_error "Fetched Ghostty commit does not match the requested commit"
        return 1
    fi

    local embedded_path="${workdir}/ghostty/src/apprt/embedded.zig"
    if [ -f "${embedded_path}" ]; then
        log_info "Disabling Ghostty window blur (App Store safe)..."
        python3 - <<PY
from pathlib import Path

path = Path("${embedded_path}")
text = path.read_text()
old = """    /// Sets the window background blur on macOS to the desired value.
    /// I do this in Zig as an extern function because I don't know how to
    /// call these functions in Swift.
    ///
    /// This uses an undocumented, non-public API because this is what
    /// every terminal appears to use, including Terminal.app.
    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        // This is only supported on macOS
        if (comptime builtin.target.os.tag != .macos) return;

        const config = &app.config;

        // Do nothing if we don't have background transparency enabled
        if (config.@\\"background-opacity\\" >= 1.0) return;

        const nswindow = objc.Object.fromId(window);
        _ = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(),
            nswindow.msgSend(usize, objc.sel(\\"windowNumber\\"), .{}),
            @intCast(config.@\\"background-blur\\".cval()),
        );
    }

    /// See ghostty_set_window_background_blur
    extern \\"c\\" fn CGSSetWindowBackgroundBlurRadius(*anyopaque, usize, c_int) i32;
    extern \\"c\\" fn CGSDefaultConnectionForThread() *anyopaque;
"""
new = """    /// Sets the window background blur on macOS to the desired value.
    /// App Store builds must avoid non-public APIs; keep this as a no-op.
    export fn ghostty_set_window_background_blur(
        app: *App,
        window: *anyopaque,
    ) void {
        _ = app;
        _ = window;
        return;
    }
"""
if old not in text:
    raise SystemExit("Ghostty private blur block not found; aborting.")
path.write_text(text.replace(old, new))
PY
    fi

    # Patch to link Metal frameworks (same as aizen)
    if [ -f "${workdir}/ghostty/pkg/macos/build.zig" ]; then
        perl -0pi -e 's/lib\.linkFramework\("IOSurface"\);/lib.linkFramework("IOSurface");\n    lib.linkFramework("Metal");\n    lib.linkFramework("MetalKit");/g' "${workdir}/ghostty/pkg/macos/build.zig"
        perl -0pi -e 's/module\.linkFramework\("IOSurface", \.\{\}\);/module.linkFramework("IOSurface", .{});\n        module.linkFramework("Metal", .{});\n        module.linkFramework("MetalKit", .{});/g' "${workdir}/ghostty/pkg/macos/build.zig"
    fi

    # IOSurfaceLayer fixes live in the Ghostty fork; no local patching here.

    # Patch bundle ID to use VVTerm's instead of Ghostty's
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
        -Demit-terminfo=true
        -Demit-termcap=false
        -Demit-themes=false
        -Doptimize=ReleaseFast
        -Dstrip
        -Dxcframework-target=universal
    )

    (cd "${workdir}/ghostty" && zig build "${zig_flags[@]}" -p "${workdir}/zig-out")

    local generated_terminfo="${workdir}/zig-out/share/terminfo"
    local bundled_terminfo="${PROJECT_ROOT}/VVTerm/Resources/terminfo"
    if [ ! -f "${generated_terminfo}/ghostty.terminfo" ] || \
       [ ! -f "${generated_terminfo}/67/ghostty" ] || \
       [ ! -f "${generated_terminfo}/78/xterm-ghostty" ]; then
        log_error "Generated Ghostty terminfo resources not found"
        exit 1
    fi

    mkdir -p "${bundled_terminfo}/67" "${bundled_terminfo}/78"
    cp "${generated_terminfo}/ghostty.terminfo" "${bundled_terminfo}/xterm-ghostty.src"
    cp "${generated_terminfo}/67/ghostty" "${bundled_terminfo}/67/ghostty"
    cp "${generated_terminfo}/78/xterm-ghostty" "${bundled_terminfo}/78/xterm-ghostty"
    /bin/bash "${SCRIPT_DIR}/validate_terminfo.sh"

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
    write_native_artifact_manifest

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

    log_info "Downloading and verifying OpenSSL ${OPENSSL_VERSION}..."
    download_verified_archive \
        "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz" \
        "openssl-${OPENSSL_VERSION}.tar.gz" \
        "${OPENSSL_SHA256}"
    rm -rf "openssl-${OPENSSL_VERSION}"
    tar xzf "openssl-${OPENSSL_VERSION}.tar.gz"

    log_info "Downloading and verifying libssh2 ${LIBSSH2_VERSION}..."
    download_verified_archive \
        "https://www.libssh2.org/download/libssh2-${LIBSSH2_VERSION}.tar.gz" \
        "libssh2-${LIBSSH2_VERSION}.tar.gz" \
        "${LIBSSH2_SHA256}"
    rm -rf "libssh2-${LIBSSH2_VERSION}"
    tar xzf "libssh2-${LIBSSH2_VERSION}.tar.gz"
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

    rsync -a --delete "${VENDOR_SSH}/macos/include/" "${VENDOR_SSH}/include/"

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
    write_native_artifact_manifest

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

main() {
    local command="${1:-all}"

    case "${command}" in
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
        verify)
            require_cmd shasum
            verify_native_sources
            ;;
        clean)
            clean
            ;;
        help|--help|-h)
            print_usage
            ;;
        *)
            log_error "Unknown command: ${command}"
            print_usage
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
