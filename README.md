# iPad AirPlay Mirror

A minimal iPadOS 17+ AirPlay screen receiver, intended for viewing an iPhone Camera preview on an iPad on the same Wi-Fi. Uses the iPhone's built-in **Control Center → Screen Mirroring**; no iPhone companion app or internet service.

## Compatibility

- **Receiver: iOS 17 / iPadOS 17 or later.** The receiver app is intended for iPad.
- **Tested on:** iPad 6th generation (A10), running **iPadOS 17.7.11**, receiving an iPhone Camera preview through native Screen Mirroring.
- Both devices must be on the same local network.
- Install from source with Xcode and Apple development signing. No jailbreak is required; there is no App Store release or prebuilt IPA in this repository.

## Features

- Native iPhone **Screen Mirroring** discovery as **iPad Mirror**, powered by UxPlay.
- Minimal black interface, with controls at the upper right and **X** farthest right.
- Independent iPad orientation and aspect-preserving video display.
- Manual counterclockwise rotation in 90° steps through a full circle.
- Viewfinder crop with pinch zoom, drag positioning, saved framing, and reset.
- Hardware H.264 display, up to the requested 720p / 30 fps.
- Local-only operation, with no account or cloud service.

**Camera orientation is manual in the current implementation.** The receiver observes changes in video geometry, but automatic tracking of the iPhone’s physical orientation in Camera has not been verified to work.

## Use

1. Open **Mirror** on the iPad and allow **Local Network** access.
2. Connect both devices to the same Wi-Fi (guest network client isolation may block discovery).
3. On the iPhone open Control Center → Screen Mirroring → **iPad Mirror**.
4. Open **Camera** on the iPhone. The app follows the iPad’s physical orientation independently of the phone. A landscape iPad displays portrait phone video upright with side bars, and fits landscape video across the wider screen. If Camera continues to send a portrait-shaped screen, tap the preview on the iPad and use **Rotate** to advance counterclockwise through **0° → 270° → 180° → 90° → 0°**. The rotation button stays visible while a manual rotation is active.
5. For an enlarged Camera preview, tap the iPad image and choose **Viewfinder** (corner-brackets icon). This crops the mirrored screen using a 4:3 Photo-mode preset. Pinch to zoom and drag to adjust framing for your Camera mode. Framing is saved separately for portrait/landscape input and manual rotation. Use the reset arrow to restore the preset; tap the button again to restore the full phone screen. It is a local crop, not a separate camera stream, and cannot recover details outside the mirrored preview.
6. Stop from the iPhone's Screen Mirroring menu, or tap the iPad preview and then **X**. The waiting screen appears immediately while network cleanup completes in the background.

The iPad stays awake while the receiver is open. Reception stops in the background and restarts on return. The app preserves aspect ratio and uses hardware H.264 decoding, requesting up to 720p at 30 fps. It mirrors the whole screen, including Camera controls. This is a preview monitor, not remote camera control or a clean HDMI feed. Audio playback is currently omitted. Latency depends on Wi-Fi; DRM video is outside the scope of this app.

AirPlay is implemented using the open-source UxPlay protocol engine rather than an official Apple receiver SDK. Compatibility with future iOS versions is not guaranteed. While the app is open, devices that can reach it on the LAN can initiate mirroring; no PIN is required in this personal-network build.

## Receiver changes

The iPad port advertises the AirPlay `ScreenRotate` capability (bit 8) and reports matching display rotation support in `/info`. UxPlay's codec geometry callback now also runs on subsequent codec packets, allowing the app to observe source geometry changes without relying only on changes to H.264 parameter sets. Incoming video never forces the iPad window scene into a different orientation. Geometry logs contain numeric sizes only.

## Build and install

Requires a Mac with Xcode and its command-line tools, an Apple development signing team, and Homebrew’s `xcodegen`, `autoconf`, `automake`, `libtool`, and `pkg-config`. Select your own signing team in Xcode, or pass `DEVELOPMENT_TEAM` as below. The included project contains the original development configuration.

```sh
brew install xcodegen autoconf automake libtool pkg-config
git clone https://github.com/bridgpal/ipad-airplay.git
cd ipad-airplay
```

```sh
./Scripts/build-dependencies.sh
xcodegen generate
xcodebuild -project Mirror.xcodeproj -scheme Mirror \
  -destination 'generic/platform=iOS' -derivedDataPath build \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=YOUR_TEAM build
xcrun devicectl list devices
xcrun devicectl device install app --device YOUR_IPAD_UDID \
  build/Build/Products/Debug-iphoneos/Mirror.app
xcrun devicectl device process launch --device YOUR_IPAD_UDID com.anil.ipadmirror
```

Only arm64 physical-device libraries are built. A simulator build needs separately compiled simulator dependencies. Generated dependency libraries and build output are ignored by Git. The generated Xcode project is included; `project.yml` is its source of truth.

## Verification

Built and signed with Xcode 27.2, installed and launched on the connected iPad 6th generation running iPadOS 17.7.11. Verified Bonjour advertisement and a live iPhone Camera image on the iPad using native iPhone Screen Mirroring. The OpenSSL build explicitly targets ARMv8-A and iOS 17 to support the iPad’s A10 processor.

## Open-source credits

- [UxPlay](https://github.com/FDH2/UxPlay), including shairplay/RPiPlay/playfair/llhttp components. Vendored protocol source and its original notices are in `Vendor/UxPlay`; upstream revision is in `Vendor/UxPlay-REVISION`.
- [OpenSSL 3.5.4](https://github.com/openssl/openssl), Apache 2.0.
- [libplist 2.7.0](https://github.com/libimobiledevice/libplist), LGPL 2.1 or later.

This project is GPL-3.0-or-later to accommodate the combined open-source receiver. See `LICENSE` and third-party notices under `Vendor`. Keep the complete corresponding sources and dependency build instructions with any distribution.
