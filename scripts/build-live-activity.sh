#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ]; then
 newest_xcode=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -t_ -k2 -V | tail -1)
 if [ -n "$newest_xcode" ]; then export DEVELOPER_DIR="$newest_xcode/Contents/Developer"; fi
fi
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
out=packages/jailed/live-activity
framework="$out/GoToHPActivity.framework"
extension="$out/GoToHPUploadProgress.appex"
mkdir -p "$framework/Modules/GoToHPActivity.swiftmodule" "$extension"
xcrun swiftc -sdk "$sdk" -target arm64-apple-ios18.0 -swift-version 5 -parse-as-library -O \
 -module-name GoToHPActivity -emit-library -emit-module -enable-library-evolution \
 -emit-module-path "$framework/Modules/GoToHPActivity.swiftmodule/arm64-apple-ios.swiftmodule" \
 -emit-module-interface-path "$framework/Modules/GoToHPActivity.swiftmodule/arm64-apple-ios.swiftinterface" \
 -Xlinker -install_name -Xlinker @rpath/GoToHPActivity.framework/GoToHPActivity \
 LiveActivity/GSUploadVisualState.swift LiveActivity/GSUploadAttributes.swift LiveActivity/GSUploadLiveActivity.swift \
 -o "$framework/GoToHPActivity"
xcrun swiftc -sdk "$sdk" -target arm64-apple-ios18.0 -swift-version 5 -parse-as-library -O \
 -module-name GoToHPUploadProgress -application-extension -F "$out" -framework GoToHPActivity \
 -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -rpath -Xlinker @executable_path/../../Frameworks \
 LiveActivity/GSUploadCard.swift LiveActivity/GSUploadWidget.swift -o "$extension/GoToHPUploadProgress"
python3 - <<'PY'
from pathlib import Path
import plistlib
root = Path('packages/jailed/live-activity')
base = {'CFBundleDevelopmentRegion':'en','CFBundleShortVersionString':'1.0','CFBundleVersion':'1','MinimumOSVersion':'18.0','CFBundleSupportedPlatforms':['iPhoneOS']}
framework = dict(base, CFBundleIdentifier='com.google.photos.gotohp.activityframework', CFBundleExecutable='GoToHPActivity', CFBundleName='GoToHPActivity', CFBundlePackageType='FMWK')
extension = dict(base, CFBundleIdentifier='com.google.photos.gotohp.uploadprogress', CFBundleExecutable='GoToHPUploadProgress', CFBundleName='GoToHP Upload Progress', CFBundleDisplayName='GoToHP', CFBundlePackageType='XPC!', UIDeviceFamily=[1,2], NSExtension={'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'})
(root/'GoToHPActivity.framework/Info.plist').write_bytes(plistlib.dumps(framework))
(root/'GoToHPUploadProgress.appex/Info.plist').write_bytes(plistlib.dumps(extension))
PY
codesign --force --sign - "$framework"
codesign --force --sign - "$extension"
