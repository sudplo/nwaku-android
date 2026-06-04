#!/bin/bash
# -----------------------------------------------------------------------------
# build_all.sh — Cross-compile nwaku for Android (arm64-v8a, x86_64)
#
# Expected container layout:
#   /app/nwaku-src   — nwaku source tree (mounted or copied)
#   /out             — output directory (mounted from host)
#
# Produces for each ABI:
#   /out/<ABI>/libwaku.so  — wakunode2 binary disguised as a shared library
#   /out/<ABI>/librln.so   — Rate-Limiting Nullifiers (RLN) shared library
# -----------------------------------------------------------------------------
set -e

echo "=============================================="
echo "  nwaku Android Cross-Compilation"
echo "=============================================="

NDK_HOME="/opt/android-ndk"
TOOLCHAIN_DIR="$NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
API_VERSION="30"   # Android 11 minimum

# ── Step 0: normalise CRLF line endings (cloned on Windows hosts) ───────────
cd /app/nwaku-src
git config --global --add safe.directory /app/nwaku-src
echo "[0/3] Normalising CRLF line endings..."
find . -type f \( -name "*.sh" -o -name "Makefile" -o -name "*.mk" \
     -o -name "*.nims" -o -name "*.cfg" -o -name "*.toml" \
     -o -name "*.nimble" \) -exec sed -i 's/\r$//' {} +

# ── Patch: Increase future timeouts in REST handlers to 20 seconds for Tor latency ──
echo "[0.5/3] Patching future timeouts in REST handlers to 20 seconds..."
find /app/nwaku-src/waku/rest_api -name "handlers.nim" -exec sed -i \
  -e 's/const futTimeout\* = 5\.seconds/const futTimeout* = 20.seconds/g' \
  -e 's/const futTimeout\* = 15\.seconds/const futTimeout* = 20.seconds/g' \
  -e 's/const FutTimeoutForPushRequestProcessing\* = 5\.seconds/const FutTimeoutForPushRequestProcessing* = 20.seconds/g' \
  -e 's/const futTimeoutForSubscriptionProcessing\* = 5\.seconds/const futTimeoutForSubscriptionProcessing* = 20.seconds/g' \
  {} +

# Verify the timeouts patch was applied
if grep -q '20.seconds' /app/nwaku-src/waku/rest_api/endpoint/store/handlers.nim; then
    echo "      REST api timeout patch applied OK ✓"
else
    echo "WARNING: REST api timeout patch may not have applied correctly!" >&2
fi


# ── Step 1: download & install Nimble dependencies ──────────────────────────
echo "[1/3] Installing Nimble dependencies (make nimbledeps)..."
make nimbledeps/.nimble-setup

NAT_DIR=$(ls -dt /app/nwaku-src/nimbledeps/pkgs2/nat_traversal-* | head -1)
if [ -z "$NAT_DIR" ]; then
    echo "ERROR: nat_traversal package not found in nimbledeps!" >&2
    exit 1
fi
echo "      nat_traversal found at: $NAT_DIR"

LSQUIC_IO=$(find /app/nwaku-src/nimbledeps/pkgs2 -path "*/lsquic/context/io.nim" | head -1)
if [ -z "$LSQUIC_IO" ]; then
    echo "ERROR: lsquic context/io.nim not found in nimbledeps!" >&2
    exit 1
fi
echo "      lsquic io.nim found at: $LSQUIC_IO"

# ── Patch: lsquic x86_64 Android type mismatch ─────────────────────────────
# In glibc (desktop Linux x86_64), Tmsghdr.msg_iovlen is size_t → csize_t.
# In Bionic (Android x86_64), msg_iovlen is int → cint.
# The nim-lsquic binding has a `when defined(linux) and defined(x86_64):` branch
# that uses csize_t, which also fires on Android x86_64. We narrow that guard
# to exclude Android so the generic `else` branch (cint) is used instead.
sed -i \
  's/when defined(linux) and defined(x86_64):/when defined(linux) and defined(x86_64) and not defined(android):/g' \
  "$LSQUIC_IO"

# Verify the patch was applied
if grep -q 'not defined(android)' "$LSQUIC_IO"; then
    echo "      lsquic patch applied OK ✓"
else
    echo "WARNING: lsquic patch may not have applied — check $LSQUIC_IO" >&2
fi

# Normalise line endings inside downloaded packages too
find "$NAT_DIR" -type f \( -name "*.sh" -o -name "Makefile" -o -name "*.mk" \
     -o -name "*.nims" -o -name "*.cfg" -o -name "*.toml" \) \
     -exec sed -i 's/\r$//' {} +

# ── Per-architecture build function ─────────────────────────────────────────
build_for_arch() {
    local ARCH=$1        # NDK arch string (e.g. aarch64-linux-android)
    local CPU=$2         # Nim --cpu value  (e.g. arm64)
    local ABI=$3         # Android ABI name (e.g. arm64-v8a)
    local RUST_TARGET=$4 # Rust target triple
    local CLANG_TARGET=$5 # Clang prefix used by NDK

    echo ""
    echo "========================================================================="
    echo "  BUILDING: $ABI  (Nim cpu=$CPU, Rust=$RUST_TARGET)"
    echo "========================================================================="

    # ── 1a: Build librln.so with Rust/Cargo ───────────────────────────────
    echo "  [a] Building librln.so with Rust..."
    pushd vendor/zerokit/rln > /dev/null
    cargo clean

    export CC="$TOOLCHAIN_DIR/bin/${CLANG_TARGET}${API_VERSION}-clang"
    export AR="$TOOLCHAIN_DIR/bin/llvm-ar"

    # Tell Cargo which linker to use for this cross target
    local CARGO_LINKER_VAR
    CARGO_LINKER_VAR="CARGO_TARGET_$(echo "$RUST_TARGET" | tr '-' '_' | tr '[:lower:]' '[:upper:]')_LINKER"
    export "$CARGO_LINKER_VAR"="$TOOLCHAIN_DIR/bin/${CLANG_TARGET}${API_VERSION}-clang"

    # Ensure 16KB page size alignment for Android 15 compatibility
    export RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384"

    cargo build --release -p rln \
        --no-default-features --features stateless \
        --target="$RUST_TARGET"
    popd > /dev/null

    mkdir -p "build/android/$ABI"
    cp "vendor/zerokit/target/$RUST_TARGET/release/librln.so" "build/android/$ABI/"

    # ── 1b: Cross-compile NAT traversal C libraries ───────────────────────
    echo "  [b] Building miniupnpc & libnatpmp for $ABI..."
    local CROSS_CC="$TOOLCHAIN_DIR/bin/${CLANG_TARGET}${API_VERSION}-clang"

    make -C "$NAT_DIR/vendor/miniupnp/miniupnpc"   CC="$CROSS_CC" clean || true
    make -C "$NAT_DIR/vendor/libnatpmp-upstream"    CC="$CROSS_CC" clean || true

    make -C "$NAT_DIR/vendor/miniupnp/miniupnpc" \
         CC="$CROSS_CC" CFLAGS="-Os -fPIC" build/libminiupnpc.a

    make -C "$NAT_DIR/vendor/libnatpmp-upstream" \
         CC="$CROSS_CC" \
         CFLAGS="-Wall -Wno-cpp -Os -fPIC -DENABLE_STRNATPMPERR -DNATPMP_MAX_RETRIES=4" \
         libnatpmp.a

    # ── 1c: Compile wakunode2 with Nim ────────────────────────────────────
    echo "  [c] Compiling wakunode2 → libwaku.so with Nim..."
    export ANDROID_COMPILER="${CLANG_TARGET}${API_VERSION}-clang"
    export ANDROID_TOOLCHAIN_DIR="$TOOLCHAIN_DIR"
    export ANDROID_ARCH="$ARCH"
    export CPU="$CPU"
    export ABIDIR="$ABI"

    nim c \
        --out:"build/android/$ABI/libwaku.so" \
        --threads:on \
        --cc:clang \
        --mm:refc \
        -d:release \
        -d:chronosEventEngine=epoll \
        -d:androidNDK \
        -d:git_version="v0.38.1" \
        --cpu:"$CPU" \
        --os:android \
        --passL:"-L/app/nwaku-src/build/android/$ABI" \
        --passL:"-Wl,--start-group" \
        --passL:"-lrln" \
        --passL:"-llog" \
        --passL:"-lm" \
        --passL:"-lc" \
        --passL:"-lc++_static" \
        --passL:"-lc++abi" \
        --passL:"-Wl,--end-group" \
        --passL:"-Wl,-rpath,\$ORIGIN" \
        --passL:"-Wl,-z,max-page-size=16384" \
        --passC:"-fPIE" \
        --passL:"-pie" \
        apps/wakunode2/wakunode2.nim

    # ── Copy outputs ──────────────────────────────────────────────────────
    mkdir -p "/out/$ABI"
    cp "build/android/$ABI/libwaku.so" "/out/$ABI/libwaku.so"
    cp "build/android/$ABI/librln.so"  "/out/$ABI/librln.so"

    echo ""
    echo "  ✓ /out/$ABI/libwaku.so  ($(du -sh "/out/$ABI/libwaku.so" | cut -f1))"
    echo "  ✓ /out/$ABI/librln.so   ($(du -sh "/out/$ABI/librln.so"  | cut -f1))"
}

# ── Targets ─────────────────────────────────────────────────────────────────
# [2/3] arm64-v8a — modern Android phones
build_for_arch \
    "aarch64-linux-android" "arm64" "arm64-v8a" \
    "aarch64-linux-android" "aarch64-linux-android"

# [3/3] x86_64 — Android emulators
build_for_arch \
    "x86_64-linux-android" "amd64" "x86_64" \
    "x86_64-linux-android" "x86_64-linux-android"

echo ""
echo "=============================================="
echo "  All targets built successfully!"
echo "=============================================="
echo ""
echo "Output:"
find /out -name "*.so" | sort | while read f; do
    echo "  $f  ($(du -sh "$f" | cut -f1))"
done
