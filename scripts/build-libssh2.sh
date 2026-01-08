#!/bin/bash
# Build libssh2 + OpenSSL for macOS and iOS (arm64 only)
# Requires: Xcode Command Line Tools

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$PROJECT_ROOT/Vendor/libssh2"
BUILD_DIR="$PROJECT_ROOT/.build/ssh"

# Versions
OPENSSL_VERSION="3.2.0"
LIBSSH2_VERSION="1.11.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Download source
download_sources() {
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # OpenSSL
    if [ ! -d "openssl-$OPENSSL_VERSION" ]; then
        log_info "Downloading OpenSSL $OPENSSL_VERSION..."
        curl -LO "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz"
        tar xzf "openssl-$OPENSSL_VERSION.tar.gz"
    fi

    # libssh2
    if [ ! -d "libssh2-$LIBSSH2_VERSION" ]; then
        log_info "Downloading libssh2 $LIBSSH2_VERSION..."
        curl -LO "https://www.libssh2.org/download/libssh2-$LIBSSH2_VERSION.tar.gz"
        tar xzf "libssh2-$LIBSSH2_VERSION.tar.gz"
    fi
}

# Build OpenSSL for macOS arm64
build_openssl_macos() {
    log_info "Building OpenSSL for macOS arm64..."
    cd "$BUILD_DIR/openssl-$OPENSSL_VERSION"

    make clean 2>/dev/null || true

    ./Configure darwin64-arm64-cc \
        --prefix="$BUILD_DIR/openssl-macos" \
        no-shared \
        no-tests

    make -j$(sysctl -n hw.ncpu)
    make install_sw

    log_info "OpenSSL macOS build complete"
}

# Build OpenSSL for iOS arm64
build_openssl_ios() {
    log_info "Building OpenSSL for iOS arm64..."
    cd "$BUILD_DIR/openssl-$OPENSSL_VERSION"

    make clean 2>/dev/null || true

    IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
    export CROSS_TOP="$(xcrun --sdk iphoneos --show-sdk-platform-path)/Developer"
    export CROSS_SDK="iPhoneOS.sdk"
    export CC="$(xcrun --sdk iphoneos -f clang) -isysroot $IOS_SDK -miphoneos-version-min=16.0"

    ./Configure ios64-xcrun \
        --prefix="$BUILD_DIR/openssl-ios" \
        -miphoneos-version-min=16.0 \
        no-shared \
        no-tests \
        no-apps

    make -j$(sysctl -n hw.ncpu) build_libs
    make install_sw

    unset CROSS_TOP CROSS_SDK CC
    log_info "OpenSSL iOS build complete"
}

# Build OpenSSL for iOS Simulator (arm64 + x86_64)
build_openssl_simulator() {
    log_info "Building OpenSSL for iOS Simulator (arm64 + x86_64)..."
    cd "$BUILD_DIR/openssl-$OPENSSL_VERSION"

    SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
    export CROSS_TOP="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)/Developer"
    export CROSS_SDK="iPhoneSimulator.sdk"

    # Build arm64
    log_info "Building OpenSSL Simulator arm64..."
    make clean 2>/dev/null || true
    export CC="$(xcrun --sdk iphonesimulator -f clang) -isysroot $SIM_SDK -arch arm64 -mios-simulator-version-min=16.0"

    ./Configure iossimulator-xcrun \
        --prefix="$BUILD_DIR/openssl-simulator-arm64" \
        -mios-simulator-version-min=16.0 \
        no-shared \
        no-tests \
        no-apps

    make -j$(sysctl -n hw.ncpu) build_libs
    make install_sw

    # Build x86_64
    log_info "Building OpenSSL Simulator x86_64..."
    make clean 2>/dev/null || true
    export CC="$(xcrun --sdk iphonesimulator -f clang) -isysroot $SIM_SDK -arch x86_64 -mios-simulator-version-min=16.0"

    ./Configure iossimulator-xcrun \
        --prefix="$BUILD_DIR/openssl-simulator-x86_64" \
        -mios-simulator-version-min=16.0 \
        no-shared \
        no-tests \
        no-apps

    make -j$(sysctl -n hw.ncpu) build_libs
    make install_sw

    # Create fat libraries
    log_info "Creating fat libraries for Simulator..."
    mkdir -p "$BUILD_DIR/openssl-simulator/lib"
    mkdir -p "$BUILD_DIR/openssl-simulator/include"
    cp -R "$BUILD_DIR/openssl-simulator-arm64/include/"* "$BUILD_DIR/openssl-simulator/include/"

    lipo -create \
        "$BUILD_DIR/openssl-simulator-arm64/lib/libcrypto.a" \
        "$BUILD_DIR/openssl-simulator-x86_64/lib/libcrypto.a" \
        -output "$BUILD_DIR/openssl-simulator/lib/libcrypto.a"

    lipo -create \
        "$BUILD_DIR/openssl-simulator-arm64/lib/libssl.a" \
        "$BUILD_DIR/openssl-simulator-x86_64/lib/libssl.a" \
        -output "$BUILD_DIR/openssl-simulator/lib/libssl.a"

    unset CROSS_TOP CROSS_SDK CC
    log_info "OpenSSL Simulator build complete"
}

# Build libssh2 for macOS arm64
build_libssh2_macos() {
    log_info "Building libssh2 for macOS arm64..."
    cd "$BUILD_DIR/libssh2-$LIBSSH2_VERSION"

    mkdir -p build-macos && cd build-macos

    cmake .. \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_INSTALL_PREFIX="$VENDOR_DIR/macos" \
        -DOPENSSL_ROOT_DIR="$BUILD_DIR/openssl-macos" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF

    make -j$(sysctl -n hw.ncpu)
    make install

    # Copy OpenSSL libs
    cp "$BUILD_DIR/openssl-macos/lib/libssl.a" "$VENDOR_DIR/macos/lib/"
    cp "$BUILD_DIR/openssl-macos/lib/libcrypto.a" "$VENDOR_DIR/macos/lib/"

    log_info "libssh2 macOS build complete"
}

# Build libssh2 for iOS arm64
build_libssh2_ios() {
    log_info "Building libssh2 for iOS arm64..."
    cd "$BUILD_DIR/libssh2-$LIBSSH2_VERSION"

    rm -rf build-ios
    mkdir -p build-ios && cd build-ios

    IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)

    cmake .. \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$IOS_SDK" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
        -DCMAKE_INSTALL_PREFIX="$VENDOR_DIR/ios" \
        -DOPENSSL_ROOT_DIR="$BUILD_DIR/openssl-ios" \
        -DOPENSSL_INCLUDE_DIR="$BUILD_DIR/openssl-ios/include" \
        -DOPENSSL_CRYPTO_LIBRARY="$BUILD_DIR/openssl-ios/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="$BUILD_DIR/openssl-ios/lib/libssl.a" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF

    make -j$(sysctl -n hw.ncpu)
    make install

    # Copy OpenSSL libs
    cp "$BUILD_DIR/openssl-ios/lib/libssl.a" "$VENDOR_DIR/ios/lib/"
    cp "$BUILD_DIR/openssl-ios/lib/libcrypto.a" "$VENDOR_DIR/ios/lib/"

    log_info "libssh2 iOS build complete"
}

# Build libssh2 for iOS Simulator (arm64 + x86_64)
build_libssh2_simulator() {
    log_info "Building libssh2 for iOS Simulator (arm64 + x86_64)..."
    cd "$BUILD_DIR/libssh2-$LIBSSH2_VERSION"

    SIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)

    # Build arm64
    log_info "Building libssh2 Simulator arm64..."
    rm -rf build-simulator-arm64
    mkdir -p build-simulator-arm64 && cd build-simulator-arm64

    cmake .. \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$SIM_SDK" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
        -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/libssh2-simulator-arm64" \
        -DOPENSSL_ROOT_DIR="$BUILD_DIR/openssl-simulator" \
        -DOPENSSL_INCLUDE_DIR="$BUILD_DIR/openssl-simulator/include" \
        -DOPENSSL_CRYPTO_LIBRARY="$BUILD_DIR/openssl-simulator/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="$BUILD_DIR/openssl-simulator/lib/libssl.a" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF

    make -j$(sysctl -n hw.ncpu)
    make install

    # Build x86_64
    log_info "Building libssh2 Simulator x86_64..."
    cd "$BUILD_DIR/libssh2-$LIBSSH2_VERSION"
    rm -rf build-simulator-x86_64
    mkdir -p build-simulator-x86_64 && cd build-simulator-x86_64

    cmake .. \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$SIM_SDK" \
        -DCMAKE_OSX_ARCHITECTURES=x86_64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
        -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/libssh2-simulator-x86_64" \
        -DOPENSSL_ROOT_DIR="$BUILD_DIR/openssl-simulator" \
        -DOPENSSL_INCLUDE_DIR="$BUILD_DIR/openssl-simulator/include" \
        -DOPENSSL_CRYPTO_LIBRARY="$BUILD_DIR/openssl-simulator/lib/libcrypto.a" \
        -DOPENSSL_SSL_LIBRARY="$BUILD_DIR/openssl-simulator/lib/libssl.a" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_TESTING=OFF

    make -j$(sysctl -n hw.ncpu)
    make install

    # Create fat library
    log_info "Creating fat libssh2 for Simulator..."
    mkdir -p "$VENDOR_DIR/ios-simulator/lib"
    mkdir -p "$VENDOR_DIR/ios-simulator/include"
    cp -R "$BUILD_DIR/libssh2-simulator-arm64/include/"* "$VENDOR_DIR/ios-simulator/include/"

    lipo -create \
        "$BUILD_DIR/libssh2-simulator-arm64/lib/libssh2.a" \
        "$BUILD_DIR/libssh2-simulator-x86_64/lib/libssh2.a" \
        -output "$VENDOR_DIR/ios-simulator/lib/libssh2.a"

    # Copy fat OpenSSL libs
    cp "$BUILD_DIR/openssl-simulator/lib/libssl.a" "$VENDOR_DIR/ios-simulator/lib/"
    cp "$BUILD_DIR/openssl-simulator/lib/libcrypto.a" "$VENDOR_DIR/ios-simulator/lib/"

    log_info "libssh2 Simulator build complete"
}

# Create module map
create_modulemap() {
    log_info "Creating module map..."

    cat > "$VENDOR_DIR/module.modulemap" << 'EOF'
module libssh2 {
    header "include/libssh2.h"
    header "include/libssh2_sftp.h"
    header "include/libssh2_publickey.h"
    link "ssh2"
    link "ssl"
    link "crypto"
    export *
}
EOF

    log_info "Module map created"
}

# Main
main() {
    log_info "Building libssh2 + OpenSSL for VivyTerm"
    log_info "======================================="

    download_sources

    case "${1:-all}" in
        macos)
            build_openssl_macos
            build_libssh2_macos
            ;;
        ios)
            build_openssl_ios
            build_libssh2_ios
            ;;
        simulator)
            build_openssl_simulator
            build_libssh2_simulator
            ;;
        all)
            build_openssl_macos
            build_libssh2_macos
            build_openssl_ios
            build_libssh2_ios
            build_openssl_simulator
            build_libssh2_simulator
            ;;
        *)
            log_error "Unknown target: $1"
            echo "Usage: $0 [macos|ios|simulator|all]"
            exit 1
            ;;
    esac

    create_modulemap

    log_info "======================================="
    log_info "Build complete!"
    log_info "Output: $VENDOR_DIR"
}

main "$@"
