#!/bin/bash
# Build libssh2 + OpenSSL for iOS and iOS Simulator
# This is a convenience wrapper around build-libssh2.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
GREEN='\033[0;32m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }

log_info "Building libssh2 + OpenSSL for iOS targets"
log_info "==========================================="

# Build iOS device
log_info "Building for iOS device..."
"${SCRIPT_DIR}/build-libssh2.sh" ios

# Build iOS Simulator
log_info "Building for iOS Simulator..."
"${SCRIPT_DIR}/build-libssh2.sh" simulator

log_info "==========================================="
log_info "iOS builds complete!"
log_info "Output:"
log_info "  - iOS device:    Vendor/libssh2/ios/"
log_info "  - iOS Simulator: Vendor/libssh2/ios-simulator/"
