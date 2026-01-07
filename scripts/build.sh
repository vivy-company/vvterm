#!/bin/bash
# VivyTerm Build Orchestrator
# Builds all vendor libraries for macOS and iOS targets

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
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

Usage: $0 [command] [options]

Commands:
  all           Build everything (macOS + iOS)
  macos         Build macOS libraries only
  ios           Build iOS libraries only
  clean         Clean build artifacts
  help          Show this help message

Options:
  --skip-ghostty    Skip libghostty build
  --skip-ssh        Skip libssh2 build
  --verbose         Enable verbose output

Examples:
  $0 all                    # Build everything
  $0 macos                  # Build macOS only
  $0 ios                    # Build iOS only
  $0 all --skip-ghostty     # Build everything except ghostty
  $0 clean                  # Clean all build artifacts

EOF
}

# Parse arguments
COMMAND="${1:-all}"
SKIP_GHOSTTY=false
SKIP_SSH=false
VERBOSE=false

shift || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-ghostty)
            SKIP_GHOSTTY=true
            shift
            ;;
        --skip-ssh)
            SKIP_SSH=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            set -x
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Check dependencies
check_deps() {
    local missing=()

    for cmd in git cmake; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if ! command -v zig >/dev/null 2>&1; then
        missing+=("zig (brew install zig)")
    fi

    if ! command -v xcrun >/dev/null 2>&1; then
        missing+=("Xcode Command Line Tools (xcode-select --install)")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing dependencies:"
        for dep in "${missing[@]}"; do
            echo "  - $dep"
        done
        exit 1
    fi

    log_info "All dependencies found"
}

# Build macOS libraries
build_macos() {
    log_section "Building macOS Libraries"

    if [ "$SKIP_GHOSTTY" = false ]; then
        log_info "Building libghostty for macOS..."
        "${SCRIPT_DIR}/build-libghostty.sh"
    else
        log_warn "Skipping libghostty (--skip-ghostty)"
    fi

    if [ "$SKIP_SSH" = false ]; then
        log_info "Building libssh2 for macOS..."
        "${SCRIPT_DIR}/build-libssh2.sh" macos
    else
        log_warn "Skipping libssh2 (--skip-ssh)"
    fi

    log_info "macOS build complete"
}

# Build iOS libraries
build_ios() {
    log_section "Building iOS Libraries"

    if [ "$SKIP_GHOSTTY" = false ]; then
        log_info "Building libghostty for iOS..."
        "${SCRIPT_DIR}/build-libghostty-ios.sh"
    else
        log_warn "Skipping libghostty (--skip-ghostty)"
    fi

    if [ "$SKIP_SSH" = false ]; then
        log_info "Building libssh2 for iOS..."
        "${SCRIPT_DIR}/build-libssh2-ios.sh"
    else
        log_warn "Skipping libssh2 (--skip-ssh)"
    fi

    log_info "iOS build complete"
}

# Clean build artifacts
clean() {
    log_section "Cleaning Build Artifacts"

    log_info "Removing .build directory..."
    rm -rf "${PROJECT_ROOT}/.build"

    log_info "Removing Vendor libraries..."
    rm -rf "${PROJECT_ROOT}/Vendor/libghostty"
    rm -rf "${PROJECT_ROOT}/Vendor/libssh2"

    log_info "Clean complete"
}

# Print build summary
print_summary() {
    log_section "Build Summary"

    echo "Vendor Libraries:"

    if [ -d "${PROJECT_ROOT}/Vendor/libghostty" ]; then
        echo "  libghostty:"
        [ -f "${PROJECT_ROOT}/Vendor/libghostty/lib/libghostty.a" ] && echo "    - macOS: $(ls -lh "${PROJECT_ROOT}/Vendor/libghostty/lib/libghostty.a" 2>/dev/null | awk '{print $5}')"
        [ -f "${PROJECT_ROOT}/Vendor/libghostty/ios/lib/libghostty.a" ] && echo "    - iOS: $(ls -lh "${PROJECT_ROOT}/Vendor/libghostty/ios/lib/libghostty.a" 2>/dev/null | awk '{print $5}')"
        [ -f "${PROJECT_ROOT}/Vendor/libghostty/ios-simulator/lib/libghostty.a" ] && echo "    - iOS Simulator: $(ls -lh "${PROJECT_ROOT}/Vendor/libghostty/ios-simulator/lib/libghostty.a" 2>/dev/null | awk '{print $5}')"
    fi

    if [ -d "${PROJECT_ROOT}/Vendor/libssh2" ]; then
        echo "  libssh2:"
        [ -f "${PROJECT_ROOT}/Vendor/libssh2/macos/lib/libssh2.a" ] && echo "    - macOS: $(ls -lh "${PROJECT_ROOT}/Vendor/libssh2/macos/lib/libssh2.a" 2>/dev/null | awk '{print $5}')"
        [ -f "${PROJECT_ROOT}/Vendor/libssh2/ios/lib/libssh2.a" ] && echo "    - iOS: $(ls -lh "${PROJECT_ROOT}/Vendor/libssh2/ios/lib/libssh2.a" 2>/dev/null | awk '{print $5}')"
        [ -f "${PROJECT_ROOT}/Vendor/libssh2/ios-simulator/lib/libssh2.a" ] && echo "    - iOS Simulator: $(ls -lh "${PROJECT_ROOT}/Vendor/libssh2/ios-simulator/lib/libssh2.a" 2>/dev/null | awk '{print $5}')"
    fi

    echo ""
    log_info "Build complete!"
}

# Main
main() {
    echo ""
    echo "  VivyTerm Build System"
    echo "  ====================="
    echo ""

    case "$COMMAND" in
        all)
            check_deps
            build_macos
            build_ios
            print_summary
            ;;
        macos)
            check_deps
            build_macos
            print_summary
            ;;
        ios)
            check_deps
            build_ios
            print_summary
            ;;
        clean)
            clean
            ;;
        help|--help|-h)
            print_usage
            ;;
        *)
            log_error "Unknown command: $COMMAND"
            print_usage
            exit 1
            ;;
    esac
}

main
