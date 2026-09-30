#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app=.build/photokit-probe/Payload/PhotoKitProbe.app
mkdir -p "$app"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
for source in experiments/photokit/Probe.m UI/GSPhotoKitCache.m UI/GSPhotoKitRangeSource.m UI/GSPhotoKitRangePump.m; do
xcrun --sdk iphoneos clang -target arm64-apple-ios15.0 -isysroot "$sdk" \
  -fobjc-arc -fblocks -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-deprecated-declarations \
  -c "$source" -o ".build/photokit-probe/$(basename "$source").o"
done
xcrun swiftc -target arm64-apple-ios15.0 -sdk "$sdk" -parse-as-library -emit-object \
  UI/GSPhotoKitTaskContext.swift -o .build/photokit-probe/context.o
xcrun swiftc -target arm64-apple-ios15.0 -sdk "$sdk" \
  .build/photokit-probe/Probe.m.o .build/photokit-probe/GSPhotoKitCache.m.o .build/photokit-probe/GSPhotoKitRangeSource.m.o .build/photokit-probe/GSPhotoKitRangePump.m.o .build/photokit-probe/context.o \
  -framework UIKit -framework Foundation -framework Photos -framework AVFoundation -o "$app/PhotoKitProbe"
cp experiments/photokit/Info.plist "$app/Info.plist"
plutil -lint "$app/Info.plist"
cd .build/photokit-probe
zip -qr PhotoKitProbe_UNSIGNED.ipa Payload
