#!/usr/bin/env python3
"""Generate driver/KeyboardDriver.xcodeproj: the FieldLab fixture app and the KeyboardDriverUITests bundle.

Kept out of iOS/Harness.xcodeproj so the product project (and CI's generator diff check) is untouched.
"""
from pathlib import Path
import hashlib, json

HERE = Path(__file__).resolve().parent
PROJ = HERE / "KeyboardDriver.xcodeproj"

def ident(name): return hashlib.sha256(("kd:" + name).encode()).hexdigest()[:24].upper()
def q(text): return json.dumps(str(text))

objects = []
def obj(name, body): objects.append(f"\t\t{ident(name)} = {{ {body} }};")

app_sources = sorted((HERE / "FieldLab").glob("*.swift"))
test_sources = sorted((HERE / "UITests").glob("*.swift"))
storekit = HERE / "Harness.storekit"

for group, paths in [("FieldLab", app_sources), ("UITests", test_sources)]:
    for p in paths:
        obj(f"file:{group}/{p.name}", f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(p.name)}; sourceTree = \"<group>\";")
        obj(f"build:{group}/{p.name}", f"isa = PBXBuildFile; fileRef = {ident(f'file:{group}/{p.name}')};")
obj("file:storekit", f"isa = PBXFileReference; lastKnownFileType = text; path = {q(storekit.name)}; sourceTree = \"<group>\";")
obj("build:storekit", f"isa = PBXBuildFile; fileRef = {ident('file:storekit')};")

obj("product:app", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = FieldLab.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj("product:tests", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = KeyboardDriverUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')

def refs(group, paths): return ",".join(ident(f"file:{group}/{p.name}") for p in paths)
def builds(group, paths): return ",".join(ident(f"build:{group}/{p.name}") for p in paths)
obj("group:FieldLab", f"isa = PBXGroup; children = ({refs('FieldLab', app_sources)}); path = FieldLab; sourceTree = \"<group>\";")
obj("group:UITests", f"isa = PBXGroup; children = ({refs('UITests', test_sources)}); path = UITests; sourceTree = \"<group>\";")
obj("group:products", f"isa = PBXGroup; children = ({ident('product:app')},{ident('product:tests')}); name = Products; sourceTree = \"<group>\";")
obj("group:root", f"isa = PBXGroup; children = ({ident('group:FieldLab')},{ident('group:UITests')},{ident('file:storekit')},{ident('group:products')}); sourceTree = \"<group>\";")

obj("app:sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({builds('FieldLab', app_sources)}); runOnlyForDeploymentPostprocessing = 0;")
obj("app:frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
obj("app:resources", "isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
obj("tests:sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({builds('UITests', test_sources)}); runOnlyForDeploymentPostprocessing = 0;")
obj("tests:frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
obj("tests:resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({ident('build:storekit')}); runOnlyForDeploymentPostprocessing = 0;")

obj("proxy:app", f"isa = PBXContainerItemProxy; containerPortal = {ident('project')}; proxyType = 1; remoteGlobalIDString = {ident('target:app')}; remoteInfo = FieldLab;")
obj("dep:app", f"isa = PBXTargetDependency; target = {ident('target:app')}; targetProxy = {ident('proxy:app')};")

common = {
    "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "26.0", "SWIFT_VERSION": "5.0", "TARGETED_DEVICE_FAMILY": "1",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator", "ONLY_ACTIVE_ARCH": "YES", "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
    "DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES", "CLANG_ENABLE_MODULES": "YES",
    # Simulator only: "Sign to Run Locally" (ad-hoc), no team or profile.
    "CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": "-", "DEVELOPMENT_TEAM": "",
    "MARKETING_VERSION": "1.0", "CURRENT_PROJECT_VERSION": "1", "GENERATE_INFOPLIST_FILE": "YES",
}
app = {"PRODUCT_NAME": "FieldLab", "PRODUCT_BUNDLE_IDENTIFIER": "org.harness.fieldlab",
       "INFOPLIST_KEY_UILaunchScreen_Generation": "YES", "INFOPLIST_KEY_CFBundleDisplayName": "FieldLab",
       "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
       "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks"}
tests = {"PRODUCT_NAME": "KeyboardDriverUITests", "PRODUCT_BUNDLE_IDENTIFIER": "org.harness.fieldlab.uitests",
         "TEST_TARGET_NAME": "FieldLab", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @loader_path/Frameworks"}
for kind, settings in [("project", common), ("app", app), ("tests", tests)]:
    values = " ".join(f"{k} = {q(v)};" for k, v in settings.items())
    obj(f"config:{kind}", f"isa = XCBuildConfiguration; buildSettings = {{ {values} }}; name = Debug;")
    obj(f"configs:{kind}", f"isa = XCConfigurationList; buildConfigurations = ({ident('config:' + kind)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;")

obj("target:app", f"isa = PBXNativeTarget; buildConfigurationList = {ident('configs:app')}; buildPhases = ({ident('app:sources')},{ident('app:frameworks')},{ident('app:resources')}); buildRules = (); dependencies = (); name = FieldLab; productName = FieldLab; productReference = {ident('product:app')}; productType = \"com.apple.product-type.application\";")
obj("target:tests", f"isa = PBXNativeTarget; buildConfigurationList = {ident('configs:tests')}; buildPhases = ({ident('tests:sources')},{ident('tests:frameworks')},{ident('tests:resources')}); buildRules = (); dependencies = ({ident('dep:app')}); name = KeyboardDriverUITests; productName = KeyboardDriverUITests; productReference = {ident('product:tests')}; productType = \"com.apple.product-type.bundle.ui-testing\";")
obj("project", f"isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; TargetAttributes = {{ {ident('target:app')} = {{ CreatedOnToolsVersion = 26.0; }}; {ident('target:tests')} = {{ CreatedOnToolsVersion = 26.0; TestTargetID = {ident('target:app')}; }}; }}; }}; buildConfigurationList = {ident('configs:project')}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {ident('group:root')}; productRefGroup = {ident('group:products')}; projectDirPath = \"\"; projectRoot = \"\"; targets = ({ident('target:app')},{ident('target:tests')});")

PROJ.mkdir(exist_ok=True)
(PROJ / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 60;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {ident('project')};\n}}\n")

app_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target:app")}" BuildableName="FieldLab.app" BlueprintName="FieldLab" ReferencedContainer="container:KeyboardDriver.xcodeproj"/>'
test_ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target:tests")}" BuildableName="KeyboardDriverUITests.xctest" BlueprintName="KeyboardDriverUITests" ReferencedContainer="container:KeyboardDriver.xcodeproj"/>'
storekit_ref = '<StoreKitConfigurationFileReference identifier="../Harness.storekit"/>'
schemes = PROJ / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / "KeyboardDriver.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="NO">{app_ref}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" shouldUseLaunchSchemeArgsEnv="YES">
<Testables><TestableReference skipped="NO" parallelizable="NO">{test_ref}</TestableReference></Testables>
{storekit_ref}
</TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.PosixSpawn" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO">
<BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable>
{storekit_ref}
</LaunchAction>
</Scheme>
''')
print(f"Generated {PROJ.name}: FieldLab ({len(app_sources)} files), KeyboardDriverUITests ({len(test_sources)} files)")
