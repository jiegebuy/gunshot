#!/bin/bash
set -euo pipefail
# Called by test-live-activity-ui.sh with an already booted simulator and host.
device="$1"
out=.build/live-activity-ui
project="$out/LockScreenTests.xcodeproj"
mkdir -p "$project/xcshareddata/xcschemes"
cat > "$project/project.pbxproj" <<'PBX'
// !$*UTF8*$!
{
 archiveVersion = 1; classes = {}; objectVersion = 56;
 objects = {
  A00000000000000000000001 = {isa = PBXProject; buildConfigurationList = A00000000000000000000002; compatibilityVersion = "Xcode 14.0"; mainGroup = A00000000000000000000003; productRefGroup = A00000000000000000000004; projectDirPath = ""; projectRoot = ""; targets = (A00000000000000000000005); };
  A00000000000000000000002 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000006); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
  A00000000000000000000003 = {isa = PBXGroup; children = (A00000000000000000000004, A00000000000000000000007); sourceTree = "<group>"; };
  A00000000000000000000004 = {isa = PBXGroup; children = (A00000000000000000000008); name = Products; sourceTree = "<group>"; };
  A00000000000000000000005 = {isa = PBXNativeTarget; buildConfigurationList = A00000000000000000000009; buildPhases = (A00000000000000000000010, A00000000000000000000011); buildRules = (); dependencies = (); name = LockScreenTests; productName = LockScreenTests; productReference = A00000000000000000000008; productType = "com.apple.product-type.bundle.ui-testing"; };
  A00000000000000000000006 = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = iphonesimulator; IPHONEOS_DEPLOYMENT_TARGET = 18.0; SWIFT_VERSION = 5.0;}; name = Debug; };
  A00000000000000000000007 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "../../tests/live_activity_lockscreen.swift"; sourceTree = SOURCE_ROOT; };
  A00000000000000000000008 = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = LockScreenTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
  A00000000000000000000009 = {isa = XCConfigurationList; buildConfigurations = (A00000000000000000000012); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
  A00000000000000000000010 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (A00000000000000000000013); runOnlyForDeploymentPostprocessing = 0; };
  A00000000000000000000011 = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
  A00000000000000000000012 = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_BUNDLE_IDENTIFIER = dev.tqmane.gunshot.lockscreentests; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGNING_ALLOWED = NO; SWIFT_VERSION = 5.0; }; name = Debug; };
  A00000000000000000000013 = {isa = PBXBuildFile; fileRef = A00000000000000000000007; };
 }; rootObject = A00000000000000000000001;
}
PBX
cat > "$project/xcshareddata/xcschemes/LockScreenTests.xcscheme" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
 <BuildAction><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000005" BuildableName="LockScreenTests.xctest" BlueprintName="LockScreenTests" ReferencedContainer="container:LockScreenTests.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000005" BuildableName="LockScreenTests.xctest" BlueprintName="LockScreenTests" ReferencedContainer="container:LockScreenTests.xcodeproj"/></TestableReference></Testables></TestAction>
</Scheme>
XML
set +e
xcrun xcodebuild test -project "$project" -scheme LockScreenTests -destination "platform=iOS Simulator,id=$device" \
 -parallel-testing-enabled NO -derivedDataPath "$out/test-build" -resultBundlePath "$out/lockscreen.xcresult" > "$out/lockscreen-test.log" 2>&1
result=$?
set -e
tail -60 "$out/lockscreen-test.log"
if [ -d "$out/lockscreen.xcresult" ]; then
 xcrun xcresulttool export attachments --path "$out/lockscreen.xcresult" --output-path "$out/lockscreen-screenshots" || true
fi
xcrun simctl spawn "$device" log show --last 4m --style compact --predicate 'process == "GoToHPUploadProgress" OR process == "ActivityRenderer"' > "$out/renderer.log" 2>&1 || true
exit "$result"
