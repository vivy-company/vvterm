#!/bin/bash
set -euo pipefail

# Build GhosttyKit.xcframework (macOS + iOS + iOS Simulator) and refresh libghostty.a artifacts.
# Uses forked ghostty with custom-io branch.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${ROOT_DIR}/Vendor/libghostty"

GHOSTTY_REPO="https://github.com/wiedymi/ghostty"
GHOSTTY_BRANCH="custom-io"

# Bundle ID for VivyTerm (prevents loading user's Ghostty config)
BUNDLE_ID="app.vivy.VivyTerm"

REF="${1:-${GHOSTTY_BRANCH}}"

echo "Building GhosttyKit.xcframework @ ${REF} (custom-io fork)"

for cmd in git zig xcodebuild rsync; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: $cmd required (try 'brew install $cmd')" >&2
        exit 1
    fi
done

WORKDIR="$(mktemp -d "/tmp/ghosttykit.XXXXXX")"
cleanup() {
    if [ "${KEEP_WORKDIR:-0}" = "1" ]; then
        echo "Keeping workdir: ${WORKDIR}"
        return
    fi
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

echo "Cloning ghostty fork (custom-io branch)..."
git clone --filter=blob:none --branch "${GHOSTTY_BRANCH}" --depth 1 "${GHOSTTY_REPO}" "${WORKDIR}/ghostty"

cd "${WORKDIR}/ghostty"

# Patch to link Metal frameworks (same as aizen)
if [ -f "${WORKDIR}/ghostty/pkg/macos/build.zig" ]; then
    perl -0pi -e 's/lib\.linkFramework\("IOSurface"\);/lib.linkFramework("IOSurface");\n    lib.linkFramework("Metal");\n    lib.linkFramework("MetalKit");/g' "${WORKDIR}/ghostty/pkg/macos/build.zig"
    perl -0pi -e 's/module\.linkFramework\("IOSurface", \.\{\}\);/module.linkFramework("IOSurface", .{});\n        module.linkFramework("Metal", .{});\n        module.linkFramework("MetalKit", .{});/g' "${WORKDIR}/ghostty/pkg/macos/build.zig"
fi

# Patch IOSurfaceLayer for iOS
if [ -f "${WORKDIR}/ghostty/src/renderer/metal/IOSurfaceLayer.zig" ]; then
    perl -0pi -e 's/const std = @import\\(\"std\"\\);/const std = @import(\"std\");\\nconst builtin = @import(\"builtin\");/' "${WORKDIR}/ghostty/src/renderer/metal/IOSurfaceLayer.zig"
    perl -0pi -e 's/const CALayer =\\s*\\n\\s*objc\\.getClass\\(\"CALayer\"\\) orelse return error\\.ObjCFailed;/const base_layer = switch (comptime builtin\\.os\\.tag) {\\n        \\.ios => objc\\.getClass\\(\"CAIOSurfaceLayer\"\\) orelse\\n            objc\\.getClass\\(\"CALayer\"\\) orelse return error\\.ObjCFailed,\\n        else => objc\\.getClass\\(\"CALayer\"\\) orelse return error\\.ObjCFailed,\\n    };/' "${WORKDIR}/ghostty/src/renderer/metal/IOSurfaceLayer.zig"
    perl -0pi -e 's/objc\\.allocateClassPair\\(CALayer, \"IOSurfaceLayer\"\\)/objc.allocateClassPair(base_layer, \"IOSurfaceLayer\")/' "${WORKDIR}/ghostty/src/renderer/metal/IOSurfaceLayer.zig"
    perl -0pi -e 's/layer\\.setProperty\\(\"contentsGravity\", macos\\.animation\\.kCAGravityTopLeft\\);/layer.setProperty(\"contentsGravity\", macos.animation.kCAGravityTopLeft);\\n    layer.setProperty(\"opaque\", true);/' "${WORKDIR}/ghostty/src/renderer/metal/IOSurfaceLayer.zig"
fi

# Patch bundle ID to use VivyTerm's instead of Ghostty's
sed -i '' "s/com\.mitchellh\.ghostty/${BUNDLE_ID}/g" "${WORKDIR}/ghostty/src/build_config.zig"

echo "Applied patches: bundle ID -> ${BUNDLE_ID}"

ZIG_FLAGS=(
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

OUTDIR="${WORKDIR}/zig-out"
echo "Building GhosttyKit.xcframework..."
(cd "${WORKDIR}/ghostty" && zig build "${ZIG_FLAGS[@]}" -p "${OUTDIR}")

XCFRAMEWORK_PATH="${OUTDIR}/macos/GhosttyKit.xcframework"
if [ ! -d "${XCFRAMEWORK_PATH}" ]; then
    echo "Error: ${XCFRAMEWORK_PATH} not found" >&2
    exit 1
fi

pick_lib() {
    local pattern="$1"
    local label="$2"
    local matches
    IFS=$'\n' read -r -d '' -a matches < <(find "${XCFRAMEWORK_PATH}" -path "${pattern}" -type f -print0)
    if [ "${#matches[@]}" -ne 1 ]; then
        echo "Error: expected 1 ${label} lib, found ${#matches[@]}" >&2
        printf '%s\n' "${matches[@]}" >&2
        exit 1
    fi
    printf '%s\n' "${matches[0]}"
}

MACOS_LIB="$(pick_lib "*/macos-*/libghostty.a" "macOS")"
IOS_LIB="$(pick_lib "*/ios-arm64/libghostty.a" "iOS device")"
SIM_LIB="$(pick_lib "*/ios-arm64-simulator/libghostty.a" "iOS simulator")"

mkdir -p "${VENDOR_DIR}/lib" "${VENDOR_DIR}/ios/lib" "${VENDOR_DIR}/ios-simulator/lib"
cp "${MACOS_LIB}" "${VENDOR_DIR}/lib/libghostty.a"
cp "${IOS_LIB}" "${VENDOR_DIR}/ios/lib/libghostty.a"
cp "${SIM_LIB}" "${VENDOR_DIR}/ios-simulator/lib/libghostty.a"

if [ -d "${WORKDIR}/ghostty/include" ]; then
    mkdir -p "${VENDOR_DIR}/include" "${VENDOR_DIR}/ios/include" "${VENDOR_DIR}/ios-simulator/include"
    rsync -a --exclude='module.modulemap' "${WORKDIR}/ghostty/include/" "${VENDOR_DIR}/include/"
    rsync -a --exclude='module.modulemap' "${WORKDIR}/ghostty/include/" "${VENDOR_DIR}/ios/include/"
    rsync -a --exclude='module.modulemap' "${WORKDIR}/ghostty/include/" "${VENDOR_DIR}/ios-simulator/include/"
fi

rm -rf "${VENDOR_DIR}/GhosttyKit.xcframework"
rsync -a "${XCFRAMEWORK_PATH}" "${VENDOR_DIR}/"

printf "%s\n" "$(git -C "${WORKDIR}/ghostty" rev-parse HEAD)" > "${VENDOR_DIR}/VERSION"

for lib in "${VENDOR_DIR}/lib/libghostty.a" \
           "${VENDOR_DIR}/ios/lib/libghostty.a" \
           "${VENDOR_DIR}/ios-simulator/lib/libghostty.a"; do
    xcrun strip -S -x "${lib}" || strip -S -x "${lib}"
done

echo "Done:"
echo "  macOS: $(ls -lh "${VENDOR_DIR}/lib/libghostty.a" | awk '{print $5}')"
echo "  iOS: $(ls -lh "${VENDOR_DIR}/ios/lib/libghostty.a" | awk '{print $5}')"
echo "  iOS Simulator: $(ls -lh "${VENDOR_DIR}/ios-simulator/lib/libghostty.a" | awk '{print $5}')"
echo "Version: $(cat "${VENDOR_DIR}/VERSION")"
