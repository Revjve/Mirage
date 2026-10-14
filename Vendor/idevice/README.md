# Vendor/idevice

This folder is populated by CI, not committed. After the download step it holds:

```
Vendor/idevice/
  IDevice.xcframework      <- the FFI library (wraps static archives per platform)
  plist.xcframework        <- libplist, a SEPARATE module
```

Both are linked by `project.yml` with `embed: false`, because they wrap static
archives — there's nothing to embed in the app bundle.

## Why it's downloaded instead of declared as a dependency

`jkcoxson/idevice` **cannot** be used as a SwiftPM package dependency: its
`Package.swift` lives in the repo's `swift/` subdirectory, and SwiftPM requires one at
the repository root. Upstream publishes a prebuilt `idevice-xcframework-<version>.zip`
with each release (~203 MB), which is what the workflow fetches and caches.

## Module names — this bit is easy to get wrong

Upstream's `swift/include/module.modulemap` declares the module as **`IDevice`**, capital
I and capital D — *not* `idevice`. And `plist` is a separate framework module. So
`DeviceLink.swift` needs both:

```swift
import IDevice
import plist   // plist_t, plist_free, plist_get_uint_val
```

## Version pinning

The workflow pins `IDEVICE_VERSION` (currently `v0.1.68`). Bump it deliberately: the FFI
symbols `DeviceLink.swift` calls must exist in that version's generated `idevice.h`, and
a silent floating version is how you get `Undefined symbol` on an unrelated commit.

## Building it yourself instead

Upstream's `justfile` has the canonical device recipe, run from `ffi/`:

```bash
BINDGEN_EXTRA_CLANG_ARGS="--sysroot=$(xcrun --sdk iphoneos --show-sdk-path)" \
  IPHONEOS_DEPLOYMENT_TARGET=17.0 \
  cargo build --release --target aarch64-apple-ios --features obfuscate
```

Note the deployment target: **17.0**, which is why `project.yml` also targets 17.0.
`just xcframework` assembles the full multi-platform xcframework (requires a Mac).
