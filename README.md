# Mirage

On-device location simulation for iOS. Mirage runs **on** the iPhone and drives that
same phone's location through Apple's `LocationSimulation` DVT channel — the mechanism
behind Xcode's *Debug → Simulate Location*.

Nothing here jailbreaks or bypasses code signing. The developer disk image it mounts is
**personalized and Apple-signed**, validated against the phone's own `UniqueChipID`
(`DeviceLink.mountDDI`). It needs your physical device and a trust pairing.

## Layout

```
App/
  MirageApp.swift            entry point, one shared controller
  Engine/
    DeviceLink.swift         idevice FFI: tunnel → RSD → DDI mount → location channel
    SpoofController.swift    hold / walk / heartbeat / reconnect-with-backoff
    Geo.swift                distance, lerp, RouteWalker, GPX reader
    Files.swift              pairing file + DDI storage
  Views/
    ContentView.swift        tab shell + shared status pill
    MapTab.swift             tap or type "lat, lon", hold a position
    RouteTab.swift           import GPX, set pace, walk it
    SetupTab.swift           pairing file, DDI download, engine settings
    LogTab.swift             step-by-step log (this is where failures explain themselves)
  Support/
    Info.plist               Files-app sharing, location purpose string
    Mirage.entitlements      network extension (only if you ship your own tunnel)
project.yml                  XcodeGen spec
```

## How it behaves

- **Hold a position** — re-sent every 4s. iOS drops the simulated fix if the channel goes
  quiet, so the heartbeat isn't optional.
- **Walk a route** — one update per second, advancing `speed × tick` metres with optional
  jitter. Pace is distance-based, so a 12-point GPX and a 1200-point GPX move identically.
- **Failure** — the link closes and rebuilds with exponential backoff (1s → 30s cap).
  A route retries the same position rather than skipping ahead.
- **Stop** — `clear()` hands control back to real GPS; the tunnel stays up.

## The one gap

`DeviceLink.openTunnel` dials **`10.7.0.1:49152`** and assumes a loopback RemotePairing
tunnel is already listening there. That tunnel is a separate piece, and it's the only
thing still missing:

- **Option 1 — external provider (easiest).** Install **LocalDevVPN** from the App Store
  (`id6755608044`) and enable it. It is a standalone loopback VPN, *not* part of StikDebug
  — StikDebug consumes the same tunnel Mirage does, so Mirage does not need StikDebug at
  all, only LocalDevVPN plus a pairing file. Being an App Store app it also costs no
  sideload slot and never expires. Keep
  `com.apple.developer.networking.networkextension` out of `Mirage.entitlements` and
  Mirage signs on a **free** Apple account.

  Wi-Fi must be on and connected, per upstream's own troubleshooting — the loopback
  tunnel will not come up on cellular alone.
- **Option 2 — ship your own.** Add an `NEPacketTunnelProvider` target (a port of
  `em_proxy`) and keep the entitlement. This needs a **paid** Apple Developer account —
  a free personal team cannot sign `packet-tunnel-provider`.

Tell me which and I'll build it out.

## Before it compiles

1. **Verify the `idevice` package pin** in `project.yml`. I could not confirm the Swift
   product name or a good tag from public sources, so that block is marked `TODO(verify)`
   and is not to be trusted as written. The FFI symbols `DeviceLink.swift` calls must match
   whatever version you pin — StikDebug's own `Package.resolved` is the best reference for
   a known-good pairing.
2. **You need macOS.** You're authoring on Windows, which is fine, but Swift/SwiftUI for
   iOS only builds on a Mac. Either copy the folder to one, or build in CI on a
   `macos-latest` GitHub Actions runner — the XcodeGen spec exists so the project can be
   generated on either without a binary `.xcodeproj` in the repo.
   ```bash
   brew install xcodegen && xcodegen generate && open Mirage.xcodeproj
   ```
3. **Sideload it.** Mirage is not an App Store app; it needs a dev cert (AltStore,
   SideStore, or Xcode directly).

## Setup on the phone

1. **Pairing file** — generate on-device with **StikPair**, or drop `pairingFile.plist`
   into *Files → On My iPhone → Mirage*. `PairingStore.adoptFromDocuments()` picks up the
   newer copy automatically. (No PC-side `pair_phone.py` needed.)
2. **Disk image** — *Setup → Download image*, ~20 MB, once. Mirage picks the cryptex
   variant on iOS 26.4+ and the personalized one below that. The mount survives until the
   phone reboots.

## Known limits

- **Backgrounding stalls a route.** Mirage holds no background execution mode, so iOS
  suspends the 1s tick. Routes need the app foregrounded. Adding a background mode means
  adding a real reason for one — ask if you want that.
- **Reboot clears the mount**, so step 2 of setup repeats after a restart (download is
  cached; the mount is not).
