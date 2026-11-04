#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="$ROOT/Vendor/Dependencies"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ipad-mirror-deps.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"
# Prerequisites: Xcode CLI tools, autoconf, automake, libtool, pkg-config.
curl -fL https://www.openssl.org/source/openssl-3.5.4.tar.gz -o "$WORK/openssl.tar.gz"
echo '967311f84955316969bdb1d8d4b983718ef42338639c621ec4c34fddef355e99  '"$WORK/openssl.tar.gz" | shasum -a 256 -c -
tar xzf "$WORK/openssl.tar.gz" -C "$WORK"
cd "$WORK/openssl-3.5.4"
./Configure ios64-xcrun no-shared no-tests no-apps no-docs --prefix="$PREFIX" -miphoneos-version-min=17.0 -march=armv8-a
make -j8
make install_sw
git clone --depth 1 --branch 2.7.0 https://github.com/libimobiledevice/libplist.git "$WORK/libplist"
cd "$WORK/libplist"
./autogen.sh --without-cython --disable-tools --disable-tests
make distclean
export CC="$CLANG" CXX="$(xcrun --sdk iphoneos -f clang++)"
export CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=17.0"
export CXXFLAGS="$CFLAGS"
./configure --host=aarch64-apple-darwin --prefix="$PREFIX" --disable-shared --without-cython --disable-tools --disable-tests
make -C libcnary -j8
make -C src libplist-2.0.la -j8
mkdir -p "$PREFIX/lib" "$PREFIX/include/plist"
cp src/.libs/libplist-2.0.a "$PREFIX/lib/"
cp include/plist/*.h "$PREFIX/include/plist/"
