# Vendor/idevice

Two files need to land in this folder before Mirage will link:

```
Vendor/idevice/
  idevice.h             <- the C header declaring the FFI surface
  libidevice_ffi.a      <- the prebuilt static archive (arm64, device)
  module.modulemap      <- already here; do not rename the module
```

`DeviceLink.swift` does `import idevice`, which resolves through `module.modulemap`
to `idevice.h`. The archive is linked via `-lidevice_ffi` (see `project.yml`).

## Where to get them

`idevice` is Jackson Coxson's Rust reimplementation of the pymobiledevice3 protocols.
It is **not** a SwiftPM package — StikJIT consumes it as this exact header + archive pair.
Either:

1. **Lift them from StikJIT/StikDebug**, which bundle a known-good pair, or
2. **Build from the Rust source** (`jkcoxson/idevice`), which is more reproducible:
   ```bash
   rustup target add aarch64-apple-ios
   cargo build --release --target aarch64-apple-ios
   ```
   then copy the resulting `.a` here and generate/copy the matching header.

Option 2 is preferable because it lets you control the archive's minimum-iOS, and you
aren't trusting a binary of unknown provenance.

## Check the symbols match

`DeviceLink.swift` calls these. If any are missing from `idevice.h`, you have a version
mismatch and the link will fail with `Undefined symbol`:

```
rp_pairing_file_read / rp_pairing_file_free
tunnel_create_rppairing
adapter_free / rsd_handshake_free
remote_server_connect_rsd / remote_server_free
location_simulation_new / _set / _clear / _free
cryptexd_installed_ddi / cryptexd_install_ddi / cryptexd_free_installed_cryptex
cryptex1_assets_load / cryptex1_assets_free
image_mounter_connect_rsd / _copy_devices / _free / _mount_personalized_rsd
lockdownd_connect_rsd / lockdownd_get_value / lockdownd_client_free
idevice_error_free / idevice_data_free
plist_free / plist_get_uint_val
```

Note: on **iOS 26.0.1** `DDIStore.useCryptex` is false, so the `cryptex*` calls are
compiled but not exercised at runtime — the personalized path in `mountDDI` is what runs.
They still have to *exist* in the header to link.

## Check the archive's minimum iOS

```bash
vtool -show-build-version libidevice_ffi.a | grep minos
```

Anything at or below 17 is fine for this project (deployment target is 17.0).
