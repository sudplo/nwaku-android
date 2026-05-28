# nwaku-android

Cross-compilation of [nwaku](https://github.com/waku-org/nwaku) (Nim implementation of the [Waku v2](https://waku.org/) protocol) for Android, producing native shared libraries ready to be bundled in Android applications.

## What this repository produces

| File | Description |
|------|-------------|
| `libwaku.so` | The full `wakunode2` binary, disguised as a shared library so Android's `jniLibs` mechanism can ship it inside an APK and load it at runtime via `System.load()` |
| `librln.so` | The Rate-Limiting Nullifiers (RLN) cryptographic library (Rust/zerokit), required at runtime by `libwaku.so` |

Both files are compiled for:

| ABI | Target | Devices |
|-----|--------|---------|
| `arm64-v8a` | `aarch64-linux-android` | All modern Android phones (2019+) |
| `x86_64` | `x86_64-linux-android` | Android emulators on x86-64 PCs / Macs |

> **Android 15 Compatibility (16 KB page size):** Both libraries are compiled with `16 KB ELF segment alignment` (using `-Wl,-z,max-page-size=16384` for both Nim and Rust builds). This ensures they load and run properly on Android 15 devices with 16 KB page sizes enabled, while remaining fully backward-compatible with standard 4 KB page devices.

> **Why no `armeabi-v7a`?** Google Play has required 64-bit support since 2019, and all devices shipped after ~2017 run 64-bit kernels. Targeting only 64-bit architectures avoids a known 32-bit compilation bug in the `stint` library (a Nim big-integer dependency) without requiring any source patches.

---

## Pre-built releases

Each tagged release includes a ZIP archive for each ABI:

- `waku-android-arm64-v8a.zip` → `arm64-v8a/libwaku.so` + `arm64-v8a/librln.so`
- `waku-android-x86_64.zip` → `x86_64/libwaku.so` + `x86_64/librln.so`

See the [Releases](../../releases) page to download the latest pre-built binaries.

---

## Build environment

| Component | Version |
|-----------|---------|
| Base OS | Ubuntu 22.04 |
| Android NDK | r26b (LLVM 17) |
| Rust toolchain | stable (matches LLVM 17) |
| Nim compiler | 2.2.4 |
| nwaku | v0.38.1 (commit `c738c7b`) |
| API level | 30 (Android 11) |

The NDK r26b is chosen because it ships LLVM 17, the same major version used by Rust stable, which eliminates linker (LLD) bitcode incompatibilities when linking Nim code against Rust static/shared libraries.

---

## Building locally

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- Git

### Steps

```bash
# 1. Clone this repository
git clone https://github.com/sudplo/nwaku-android.git
cd nwaku-android

# 2. Clone nwaku source code at the pinned commit
git clone https://github.com/waku-org/nwaku.git ./nwaku-src
cd nwaku-src
git checkout c738c7b65ed0a3b7ce45c201c1d83038aabc0231
git submodule update --init --recursive
cd ..

# 3. Build the Docker builder image
docker build -t nwaku-android-builder .

# 4. Run the compilation (outputs go to ./out/<ABI>/)
mkdir -p out
docker run --rm \
  -v "$(pwd)/nwaku-src:/app/nwaku-src" \
  -v "$(pwd)/out:/out" \
  nwaku-android-builder
```

After the build, you will find:

```
out/
├── arm64-v8a/
│   ├── libwaku.so   (~25 MB)
│   └── librln.so    (~5 MB)
└── x86_64/
    ├── libwaku.so   (~25 MB)
    └── librln.so    (~5 MB)
```

---

## Using in an Android project

1. Copy the `.so` files into your Android module's `jniLibs`:

```
app/src/main/jniLibs/
├── arm64-v8a/
│   ├── libwaku.so
│   └── librln.so
└── x86_64/
    ├── libwaku.so
    └── librln.so
```

2. Load and execute from Java/Kotlin:

```kotlin
// Load the RLN dependency first, then the main binary
System.loadLibrary("rln")
System.loadLibrary("waku")

// Or execute libwaku.so directly as a native process from the native libs dir
val libDir = context.applicationInfo.nativeLibraryDir
val waku = ProcessBuilder("$libDir/libwaku.so", "--config-file=/path/to/config.toml")
    .redirectErrorStream(true)
    .start()
```

---

## GitHub Actions — automated builds

The workflow at [`.github/workflows/build.yml`](.github/workflows/build.yml) automatically:

1. Clones nwaku at the pinned commit
2. Builds the Docker builder image
3. Runs the cross-compilation inside Docker
4. On every **push to `master`** or manual trigger (`workflow_dispatch`): uploads artifacts
5. On every **tag push** matching `v*.*`: creates a **GitHub Release** and attaches the ZIP archives as release assets

To publish a new release:
```bash
git tag v0.38.1
git push origin v0.38.1
```

---

## Versioning

This repository follows the upstream `nwaku` version. The tag `v0.38.1` corresponds to nwaku v0.38.1.

---

## Licenses

- **This build tooling** (Dockerfile, scripts, workflow): MIT — see [`LICENSE`](LICENSE)
- **nwaku** (the compiled binary): Apache 2.0 / MIT dual-license — see [waku-org/nwaku](https://github.com/waku-org/nwaku/blob/master/LICENSE)
- **zerokit / RLN** (librln.so): MIT — see [vacp2p/zerokit](https://github.com/vacp2p/zerokit/blob/main/LICENSE)
