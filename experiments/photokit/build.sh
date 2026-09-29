#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app=.build/photokit-probe/Payload/PhotoKitProbe.app
mkdir -p "$app"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -target arm64-apple-ios15.0 -isysroot "$sdk" \
  -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations \
  -framework UIKit -framework Foundation -framework Photos -framework AVFoundation \
  experiments/photokit/Probe.m -o "$app/PhotoKitProbe"
cp experiments/photokit/Info.plist "$app/Info.plist"
plutil -lint "$app/Info.plist"
cd .build/photokit-probe
zip -qr PhotoKitProbe_UNSIGNED.ipa Payload
