#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ]; then
 newest_xcode=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -t_ -k2 -V | tail -1)
 if [ -n "$newest_xcode" ]; then export DEVELOPER_DIR="$newest_xcode/Contents/Developer"; fi
fi
mkdir -p .build/live-activity-ui
xcrun swiftc -swift-version 5 -parse-as-library LiveActivity/GSUploadVisualState.swift tests/upload_activity_state.swift -o .build/live-activity-ui/model-test
.build/live-activity-ui/model-test
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
arch=$(uname -m)
app=.build/live-activity-ui/Preview.app
framework="$app/Frameworks/GoToHPActivity.framework"
extension="$app/PlugIns/GoToHPUploadProgress.appex"
mkdir -p "$framework/Modules/GoToHPActivity.swiftmodule" "$extension"
xcrun swiftc -sdk "$sdk" -target "$arch-apple-ios18.0-simulator" -swift-version 5 -parse-as-library \
 -module-name GoToHPActivity -application-extension -emit-library -emit-module \
 -emit-module-path "$framework/Modules/GoToHPActivity.swiftmodule/$arch-apple-ios-simulator.swiftmodule" \
 -Xlinker -install_name -Xlinker @rpath/GoToHPActivity.framework/GoToHPActivity \
 LiveActivity/GSUploadVisualState.swift LiveActivity/GSUploadAttributes.swift LiveActivity/GSUploadLiveActivity.swift -o "$framework/GoToHPActivity"
xcrun swiftc -sdk "$sdk" -target "$arch-apple-ios18.0-simulator" -swift-version 5 -parse-as-library \
 -module-name GoToHPUploadProgress -application-extension -F "$app/Frameworks" -framework GoToHPActivity \
 -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -rpath -Xlinker @executable_path/../../Frameworks \
 LiveActivity/GSUploadCard.swift LiveActivity/GSUploadWidget.swift -o "$extension/GoToHPUploadProgress"
xcrun swiftc -sdk "$sdk" -target "$arch-apple-ios18.0-simulator" -swift-version 5 -parse-as-library \
 -F "$app/Frameworks" -framework GoToHPActivity -Xlinker -rpath -Xlinker @executable_path/Frameworks \
 LiveActivity/GSUploadCard.swift tests/live_activity_preview.swift -o "$app/Preview"
python3 - <<'PY'
from pathlib import Path
import plistlib
root=Path('.build/live-activity-ui/Preview.app')
base={'CFBundleVersion':'1','CFBundleShortVersionString':'1.0','MinimumOSVersion':'18.0'}
(root/'Info.plist').write_bytes(plistlib.dumps(dict(base,CFBundleIdentifier='dev.tqmane.gunshot.activitypreview',CFBundleExecutable='Preview',CFBundleName='Preview',CFBundlePackageType='APPL',UIDeviceFamily=[1],UILaunchScreen={},NSSupportsLiveActivities=True)))
(root/'Frameworks/GoToHPActivity.framework/Info.plist').write_bytes(plistlib.dumps(dict(base,CFBundleIdentifier='dev.tqmane.gunshot.activitypreview.model',CFBundleExecutable='GoToHPActivity',CFBundleName='GoToHPActivity',CFBundlePackageType='FMWK')))
(root/'PlugIns/GoToHPUploadProgress.appex/Info.plist').write_bytes(plistlib.dumps(dict(base,CFBundleIdentifier='dev.tqmane.gunshot.activitypreview.widget',CFBundleExecutable='GoToHPUploadProgress',CFBundleName='GoToHP Upload Progress',CFBundlePackageType='XPC!',UIDeviceFamily=[1,2],NSExtension={'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'})))
PY
codesign --force --sign - "$framework"
codesign --force --sign - "$extension"
codesign --force --sign - "$app"
python3 - <<'PY'
import json, subprocess, pathlib, shutil
def run(*args): return subprocess.check_output(args,text=True).strip()
runtimes=json.loads(run('xcrun','simctl','list','runtimes','-j'))['runtimes']
runtime=max((r for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier']),key=lambda r:tuple(map(int,r['version'].split('.'))))
types=json.loads(run('xcrun','simctl','list','devicetypes','-j'))['devicetypes']
kind=next(d for d in types if d['name']=='iPhone 16 Pro')
device=run('xcrun','simctl','create','GoToHP Live Activity Preview',kind['identifier'],runtime['identifier'])
subprocess.run(['xcrun','simctl','boot',device],check=True,timeout=90)
subprocess.run(['xcrun','simctl','bootstatus',device,'-b'],check=True,timeout=240)
subprocess.run(['xcrun','simctl','install',device,'.build/live-activity-ui/Preview.app'],check=True,timeout=120)
try:
 subprocess.run(['xcrun','simctl','launch','--console',device,'dev.tqmane.gunshot.activitypreview'],check=True,timeout=180)
except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
 subprocess.run(['xcrun','simctl','spawn',device,'log','show','--last','3m','--style','compact','--predicate','process == "Preview" OR process == "GoToHPUploadProgress"'],timeout=30)
 raise
documents=pathlib.Path(run('xcrun','simctl','get_app_container',device,'dev.tqmane.gunshot.activitypreview','data'))/'Documents'
for name in ('result.txt','live-activity-preview.png'): shutil.copy2(documents/name,pathlib.Path('.build/live-activity-ui')/name)
result=(documents/'result.txt').read_text();print(result)
assert result.startswith('PASS ')
PY
