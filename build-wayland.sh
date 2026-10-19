#!/bin/bash
# Build the driver for Bannerlator's Wayland mode and package it into dist/.
#
# One libvulkan_radeon.so with the Android platform and the Wayland window-system integration: the
# AdrenoTools list loads it for X11 games and the Wayland compositor, and the Khronos loader in the
# Wine container loads the same file as the Wayland game driver. It links libwayland-client, which
# the package bundles (with libffi and libandroid-support) from the Termux repository.
#
# usage: ./build-wayland.sh [path-to-android-ndk]
#   The NDK can also come from ANDROID_NDK_HOME or ANDROID_NDK_ROOT.
#   BUILD_DIR overrides the build directory (default: build-android-wayland).
# Requires a Linux x86-64 host (Termux's wayland-scanner is an x86-64 Linux program): meson, ninja,
# python3 (mako, packaging), glslangValidator, patchelf, curl, ar, tar, pkg-config, and network
# access (Termux packages and Meson wraps).
set -eu -o pipefail

cd "$(dirname "$0")"

die() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || die "needs a Linux x86-64 host"

NDK="${1:-${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}}"
[ -n "$NDK" ] && [ -d "$NDK" ] || die "pass the Android NDK path or set ANDROID_NDK_HOME"
BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
[ -x "$BIN/aarch64-linux-android34-clang" ] || die "no API 34 arm64 compiler in $BIN"
for tool in llvm-strip llvm-readelf llvm-ar; do
   [ -x "$BIN/$tool" ] || die "$tool not found in $BIN"
done
for tool in meson ninja python3 glslangValidator patchelf curl ar tar pkg-config; do
   command -v "$tool" >/dev/null 2>&1 || die "$tool not found in PATH"
done

BUILD="${BUILD_DIR:-build-android-wayland}"
mkdir -p "$BUILD"
BUILD="$(cd "$BUILD" && pwd)"

# Termux packages: libwayland-client and its dependencies for the phone, and a wayland-scanner of
# the same version for this machine.
TERMUX_REPO="https://packages-cf.termux.dev/apt/termux-main"
TERMUX_PKGS="libwayland libwayland-protocols libffi libandroid-support"
TERMUX_HOST_PKGS="libwayland-cross-scanner"
SYSROOT="$BUILD/termux"
TPREFIX="$SYSROOT/data/data/com.termux/files/usr"

fetch() {
   curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors "$1" -o "$2" || die "download failed: $1"
}

if [ ! -e "$TPREFIX/lib/libwayland-client.so" ] || [ ! -x "$TPREFIX/opt/libwayland/cross/bin/wayland-scanner" ]; then
   echo "fetching Termux packages: $TERMUX_PKGS $TERMUX_HOST_PKGS"
   rm -rf "$SYSROOT" "$BUILD/debs"
   mkdir -p "$SYSROOT" "$BUILD/debs"
   fetch "$TERMUX_REPO/dists/stable/main/binary-aarch64/Packages" "$BUILD/Packages"
   for p in $TERMUX_PKGS $TERMUX_HOST_PKGS; do
      fn=$(awk -v P="$p" 'BEGIN{RS="";FS="\n"} {n="";f=""; for(i=1;i<=NF;i++){if($i~/^Package: /)n=substr($i,10); if($i~/^Filename: /)f=substr($i,11)} if(n==P){print f; exit}}' "$BUILD/Packages")
      [ -n "$fn" ] || die "Termux package $p is not in the index"
      echo " - $fn"
      fetch "$TERMUX_REPO/$fn" "$BUILD/debs/$p.deb"
      rm -rf "$BUILD/debs/x" && mkdir "$BUILD/debs/x"
      (cd "$BUILD/debs/x" && ar x "../$p.deb" && tar -xf data.tar.* -C "$SYSROOT") || die "cannot unpack $p.deb"
   done
fi
for l in libwayland-client.so libffi.so libandroid-support.so; do
   [ -e "$TPREFIX/lib/$l" ] || die "the Termux packages have no $l"
done
export PATH="$TPREFIX/opt/libwayland/cross/bin:$PATH"

cat > "$BUILD/cross.ini" <<EOF
[binaries]
c = '$BIN/aarch64-linux-android34-clang'
cpp = '$BIN/aarch64-linux-android34-clang++'
ar = '$BIN/llvm-ar'
strip = '$BIN/llvm-strip'
pkg-config = '$(command -v pkg-config)'

[properties]
cpp_link_args = ['-static-libstdc++']
sys_root = '$SYSROOT'
pkg_config_libdir = ['$TPREFIX/lib/pkgconfig', '$TPREFIX/share/pkgconfig']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

if [ ! -f "$BUILD/build.ninja" ]; then
   # The options of build.sh plus the Wayland platform. android-strict=false (as in build.sh) is
   # required: strict mode hides VK_KHR_wayland_surface.
   meson setup "$BUILD" --cross-file "$BUILD/cross.ini" \
      -Dbuildtype=debugoptimized -Db_ndebug=true \
      -Dplatforms=android,wayland -Dplatform-sdk-version=34 -Dandroid-stub=true -Dandroid-strict=false \
      -Dandroid-libbacktrace=disabled \
      -Dvulkan-drivers=amd -Dgallium-drivers= -Dvulkan-layers= -Dtools= \
      -Dllvm=disabled -Dzstd=disabled -Dlmsensors=disabled -Dperfetto=false \
      -Dglx=disabled -Dgbm=disabled -Degl=disabled -Dgles1=disabled -Dgles2=disabled \
      -Dallow-fallback-for=libdrm,perfetto --force-fallback-for=expat,libdrm,zlib \
      -Dlibdrm:default_library=static -Dexpat:default_library=static -Dzlib:default_library=static \
      -Dc_args=-march=armv8.2-a -Dcpp_args=-march=armv8.2-a
fi

ninja -C "$BUILD" src/amd/vulkan/libvulkan_radeon.so

# Stage: the driver under the only file name Bannerlator's Wayland importer accepts, the bundled
# libraries next to it, all finding each other through $ORIGIN.
DRIVER=libvulkan_freedreno_radv.so
STAGE="$BUILD/stage"
rm -rf "$STAGE" && mkdir -p "$STAGE/licenses"
"$BIN/llvm-strip" -o "$STAGE/$DRIVER" "$BUILD/src/amd/vulkan/libvulkan_radeon.so"
for l in libwayland-client.so libffi.so libandroid-support.so; do
   cp -L "$TPREFIX/lib/$l" "$STAGE/$l"
done
patchelf --set-rpath '$ORIGIN' "$STAGE/$DRIVER" "$STAGE/libwayland-client.so"
for p in libwayland libffi libandroid-support; do
   for f in "$TPREFIX/share/doc/$p"/*; do
      [ -f "$f" ] && cp "$f" "$STAGE/licenses/$p-$(basename "$f")"
   done
done
chmod 644 "$STAGE"/*.so "$STAGE"/licenses/*

SYMS="$("$BIN/llvm-readelf" --dyn-syms -W "$STAGE/$DRIVER")"
"$BIN/llvm-readelf" -d "$STAGE/$DRIVER" | grep -q 'RUNPATH.*\$ORIGIN' || die "no RUNPATH \$ORIGIN"
grep -qw HMI <<<"$SYMS" || die "no HMI export: AdrenoTools cannot load the driver"
grep -q vk_icdGetInstanceProcAddr <<<"$SYMS" || die "no vk_icd* exports: the Khronos loader cannot load the driver"
[ "$(grep -c ' UND .*wl_' <<<"$SYMS" || true)" -gt 10 ] || die "the Wayland window-system integration is not in"
for sym in wl_display_dispatch_queue_timeout wl_display_create_queue_with_name wl_fixes_interface; do
   if grep -q " UND .*\b$sym\b" <<<"$SYMS"; then
      die "imports $sym: it would not load against an older libwayland-client"
   fi
done

mkdir -p dist
python3 android/package-wayland.py "$STAGE" dist
