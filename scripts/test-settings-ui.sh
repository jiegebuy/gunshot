#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app=.build/settings-smoke/GoToHPSettingsFixture.app
mkdir -p "$app" .build/settings-ui-results
mkdir -p .build/runtime-fixture
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
architecture=$(uname -m)
case "$architecture" in arm64) goarch=arm64;; x86_64) goarch=amd64;; *) exit 1;; esac
python3 scripts/prepare-core.py
CGO_ENABLED=1 GOOS=ios GOARCH="$goarch" CC="$(xcrun --sdk iphonesimulator --find clang)" \
 CGO_CFLAGS="-isysroot $sdk -target ${architecture}-apple-ios15.0-simulator" \
 CGO_LDFLAGS="-isysroot $sdk -target ${architecture}-apple-ios15.0-simulator" \
 go build -tags cli -buildmode=c-archive -o .build/runtime-fixture/libgotohp.a ./cmd/bridge
# Wrap account requests only; conditions and list go to the actual Go service.
xcrun --sdk iphonesimulator clang -fobjc-arc -isysroot "$sdk" \
 -target "${architecture}-apple-ios15.0-simulator" -DGS_JAILED=1 \
 -I.build/runtime-fixture -DGunshotRequest=GSFixtureRequest \
 -c Jailed/EmbeddedService.m -o .build/runtime-fixture/EmbeddedService.o
xcrun --sdk iphonesimulator clang -fobjc-arc -isysroot "$sdk" \
 -target "${architecture}-apple-ios15.0-simulator" \
 -DGS_JAILED=1 -I.build/runtime-fixture \
 -framework UIKit -framework Foundation -framework CoreGraphics -framework Photos -framework PhotosUI -framework Network -framework Security -framework CoreFoundation -lresolv \
 UI/GSPanel.m UI/GSAppearance.m UI/GSBatchImport.m UI/GSAlbumPicker.m UI/GSAccountConnection.m UI/GSUploadMonitor.m UI/GSBackupLifecycle.m Jailed/SideloadIdentity.m tests/settings_ui.m .build/runtime-fixture/EmbeddedService.o \
 .build/runtime-fixture/libgotohp.a -o "$app/GoToHPSettingsFixture"
python3 - <<'PY'
import pathlib,plistlib
info={"CFBundleIdentifier":"dev.tqmane.gunshot.settingsfixture","CFBundleExecutable":"GoToHPSettingsFixture","CFBundleName":"GoToHP Settings Fixture","CFBundlePackageType":"APPL","CFBundleVersion":"1","CFBundleShortVersionString":"1.0","MinimumOSVersion":"15.0","UIDeviceFamily":[1],"UILaunchScreen":{},"UIApplicationSceneManifest":{"UIApplicationSupportsMultipleScenes":False}}
pathlib.Path('.build/settings-smoke/GoToHPSettingsFixture.app/Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - "$app"
python3 - <<'PY'
import json,subprocess,pathlib,shutil
run=lambda *args:subprocess.check_output(args,text=True).strip()
# Use a fixture-owned device rather than the runner image's pre-created device.
# Install/launch on that shared seed can stall before the fixture reaches main.
runtimes=json.loads(run('xcrun','simctl','list','runtimes','-j'))['runtimes']
runtimes=[r for r in runtimes if r.get('isAvailable') and '.iOS-' in r['identifier']]
if not runtimes:raise SystemExit('No available iPhone simulator runtime')
runtime=max(runtimes,key=lambda r:tuple(map(int,r['version'].split('.'))))
types=json.loads(run('xcrun','simctl','list','devicetypes','-j'))['devicetypes']
device_type=next(d for d in types if d['name']=='iPhone 16 Pro')
udid=run('xcrun','simctl','create','GoToHP Settings CI',device_type['identifier'],runtime['identifier'])
print('Fixture device:',udid,runtime['name'],flush=True)
subprocess.run(['xcrun','simctl','boot',udid],check=True,timeout=90)
subprocess.run(['xcrun','simctl','bootstatus',udid,'-b'],check=True,timeout=180)
app='.build/settings-smoke/GoToHPSettingsFixture.app';bundle='dev.tqmane.gunshot.settingsfixture'
print('Installing settings fixture',flush=True)
subprocess.run(['xcrun','simctl','install',udid,app],check=True,timeout=120)
print('Launching settings fixture',flush=True)
launch_error=None
try:
 subprocess.run(['xcrun','simctl','launch','--console',udid,bundle],check=True,timeout=120)
except (subprocess.CalledProcessError,subprocess.TimeoutExpired) as error:
 launch_error=str(error)
 print(launch_error)
 subprocess.run(['xcrun','simctl','io',udid,'screenshot','.build/settings-ui-results/failure.png'],timeout=20)
 subprocess.run(['xcrun','simctl','spawn',udid,'log','show','--last','3m','--style','compact','--predicate','process == "GoToHPSettingsFixture"'],timeout=30)

container=pathlib.Path(run('xcrun','simctl','get_app_container',udid,bundle,'data'))/'Documents'
result=(container/'result.txt').read_text() if (container/'result.txt').exists() else 'FAIL fixture did not write a result'
for p in container.iterdir():
 if p.suffix in ['.txt','.png']:shutil.copy2(p,pathlib.Path('.build/settings-ui-results')/p.name)
print(result)
if launch_error or not result.startswith('PASS '):raise SystemExit(1)
PY
