#!/usr/bin/env python3
"""Generate the dependency-free Xcode project deterministically from iOS sources."""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parent.parent
IOS = ROOT / "iOS"
PROJECT = IOS / "Harness.xcodeproj"
PROJECT.mkdir(exist_ok=True)

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def quote(text):
    return json.dumps(str(text))

objects = []
def obj(name, body):
    objects.append(f"\t\t{ident(name)} = {{ {body} }};")

def file_kind(path):
    return {".swift": "sourcecode.swift", ".xcassets": "folder.assetcatalog", ".entitlements": "text.plist.entitlements"}.get(path.suffix, "text.plist.xml")

def ids(prefix, paths, kind):
    return ",".join(ident(f"{prefix}{kind}:{p.name}") for p in paths)

# App target: iOS/Harness
sources = sorted((IOS / "Harness").glob("*.swift"))
assert sources, "No app sources"
resources = [IOS / "Harness" / "Assets.xcassets", IOS / "Harness" / "PrivacyInfo.xcprivacy"]
app_other = [IOS / "Harness" / "Info.plist", IOS / "Harness" / "Harness.entitlements"]
for path in sources + resources + app_other:
    obj("file:" + path.name, f"isa = PBXFileReference; lastKnownFileType = {file_kind(path)}; path = {quote(path.name)}; sourceTree = \"<group>\";")
for path in sources + resources:
    obj("build:" + path.name, f"isa = PBXBuildFile; fileRef = {ident('file:' + path.name)};")

# Keyboard extension target: iOS/HarnessKeyboard (ids are prefixed; file names repeat across targets)
KBD = IOS / "HarnessKeyboard"
kbd_sources = sorted(KBD.glob("*.swift"))
assert kbd_sources, "No keyboard sources"
kbd_resources = [KBD / "PrivacyInfo.xcprivacy"]
kbd_other = [KBD / "Info.plist", KBD / "HarnessKeyboard.entitlements"]
for path in kbd_sources + kbd_resources + kbd_other:
    obj("kbd-file:" + path.name, f"isa = PBXFileReference; lastKnownFileType = {file_kind(path)}; path = {quote(path.name)}; sourceTree = \"<group>\";")
for path in kbd_sources + kbd_resources:
    obj("kbd-build:" + path.name, f"isa = PBXBuildFile; fileRef = {ident('kbd-file:' + path.name)};")

obj("app", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Harness.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj("appex", 'isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = HarnessKeyboard.appex; sourceTree = BUILT_PRODUCTS_DIR;')
obj("group-app", f"isa = PBXGroup; children = ({ids('', sources + resources + app_other, 'file')}); path = Harness; sourceTree = \"<group>\";")
obj("group-keyboard", f"isa = PBXGroup; children = ({ids('kbd-', kbd_sources + kbd_resources + kbd_other, 'file')}); path = HarnessKeyboard; sourceTree = \"<group>\";")
obj("products", f"isa = PBXGroup; children = ({ident('app')},{ident('appex')}); name = Products; sourceTree = \"<group>\";")
obj("root-group", f"isa = PBXGroup; children = ({ident('group-app')},{ident('group-keyboard')},{ident('products')}); sourceTree = \"<group>\";")
obj("sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({ids('', sources, 'build')}); runOnlyForDeploymentPostprocessing = 0;")
obj("resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({ids('', resources, 'build')}); runOnlyForDeploymentPostprocessing = 0;")
obj("kbd-sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({ids('kbd-', kbd_sources, 'build')}); runOnlyForDeploymentPostprocessing = 0;")
obj("kbd-resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({ids('kbd-', kbd_resources, 'build')}); runOnlyForDeploymentPostprocessing = 0;")

# Local packages: the portable core at the repo root, and the dictation package.
obj("local-package", 'isa = XCLocalSwiftPackageReference; relativePath = ..;')
obj("dictation-package", 'isa = XCLocalSwiftPackageReference; relativePath = ../Packages/HarnessDictation;')
def product(name, package):
    obj(f"product:{name}", f"isa = XCSwiftPackageProductDependency; package = {ident(package)}; productName = {name};")
    obj(f"product-build:{name}", f"isa = PBXBuildFile; productRef = {ident('product:' + name)};")
app_products = [("HarnessCore", "local-package"), ("DictationAppKit", "dictation-package"), ("DictationEngine", "dictation-package")]
kbd_products = [("HarnessKeyboardKit", "dictation-package")]
for name, package in app_products + kbd_products:
    product(name, package)
obj("frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({','.join(ident('product-build:' + n) for n, _ in app_products)}); runOnlyForDeploymentPostprocessing = 0;")
obj("kbd-frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({','.join(ident('product-build:' + n) for n, _ in kbd_products)}); runOnlyForDeploymentPostprocessing = 0;")

# The app embeds and depends on the keyboard extension.
obj("embed-appex", f"isa = PBXBuildFile; fileRef = {ident('appex')}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }};")
obj("embed-extensions", f"isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = \"\"; dstSubfolderSpec = 13; files = ({ident('embed-appex')}); name = \"Embed Foundation Extensions\"; runOnlyForDeploymentPostprocessing = 0;")
obj("kbd-proxy", f"isa = PBXContainerItemProxy; containerPortal = {ident('project')}; proxyType = 1; remoteGlobalIDString = {ident('kbd-target')}; remoteInfo = HarnessKeyboard;")
obj("kbd-dependency", f"isa = PBXTargetDependency; target = {ident('kbd-target')}; targetProxy = {ident('kbd-proxy')};")

for mode in ["Debug", "Release"]:
    common = {
        "CLANG_ENABLE_MODULES": "YES", "IPHONEOS_DEPLOYMENT_TARGET": "26.0", "SDKROOT": "iphoneos",
        "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "minimal", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
        "DEBUG_INFORMATION_FORMAT": "dwarf" if mode == "Debug" else "dwarf-with-dsym",
    }
    if mode == "Debug":
        common.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG", "ONLY_ACTIVE_ARCH": "YES"})
    else:
        common.update({"SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": "-O"})
    app = {
        "PRODUCT_BUNDLE_IDENTIFIER": "org.harness.ios", "PRODUCT_NAME": "$(TARGET_NAME)", "INFOPLIST_FILE": "Harness/Info.plist",
        "GENERATE_INFOPLIST_FILE": "NO", "TARGETED_DEVICE_FAMILY": "1", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SUPPORTS_MACCATALYST": "NO", "CODE_SIGN_STYLE": "Automatic", "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks", "MARKETING_VERSION": "0.1.0", "CURRENT_PROJECT_VERSION": "1",
        "CODE_SIGN_ENTITLEMENTS": "Harness/Harness.entitlements",
    }
    keyboard = {
        "PRODUCT_BUNDLE_IDENTIFIER": "org.harness.ios.keyboard", "PRODUCT_NAME": "$(TARGET_NAME)", "INFOPLIST_FILE": "HarnessKeyboard/Info.plist",
        "GENERATE_INFOPLIST_FILE": "NO", "TARGETED_DEVICE_FAMILY": "1", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SUPPORTS_MACCATALYST": "NO", "CODE_SIGN_STYLE": "Automatic", "SKIP_INSTALL": "YES",
        "CODE_SIGN_ENTITLEMENTS": "HarnessKeyboard/HarnessKeyboard.entitlements",
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks",
        "MARKETING_VERSION": "0.1.0", "CURRENT_PROJECT_VERSION": "1",
    }
    for kind, settings in [("project", common), ("target", app), ("kbd-target", keyboard)]:
        values = ' '.join(f"{key} = {quote(value)};" for key, value in settings.items())
        obj(f"{kind}-{mode}", f"isa = XCBuildConfiguration; buildSettings = {{ {values} }}; name = {mode};")
for kind in ["project", "target", "kbd-target"]:
    obj(f"{kind}-configs", f"isa = XCConfigurationList; buildConfigurations = ({ident(kind + '-Debug')},{ident(kind + '-Release')}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
obj("target", f"isa = PBXNativeTarget; buildConfigurationList = {ident('target-configs')}; buildPhases = ({ident('sources')},{ident('frameworks')},{ident('resources')},{ident('embed-extensions')}); buildRules = (); dependencies = ({ident('kbd-dependency')}); name = Harness; packageProductDependencies = ({','.join(ident('product:' + n) for n, _ in app_products)}); productName = Harness; productReference = {ident('app')}; productType = \"com.apple.product-type.application\";")
obj("kbd-target", f"isa = PBXNativeTarget; buildConfigurationList = {ident('kbd-target-configs')}; buildPhases = ({ident('kbd-sources')},{ident('kbd-frameworks')},{ident('kbd-resources')}); buildRules = (); dependencies = (); name = HarnessKeyboard; packageProductDependencies = ({','.join(ident('product:' + n) for n, _ in kbd_products)}); productName = HarnessKeyboard; productReference = {ident('appex')}; productType = \"com.apple.product-type.app-extension\";")
obj("project", f"isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; TargetAttributes = {{ {ident('target')} = {{ CreatedOnToolsVersion = 26.0; }}; {ident('kbd-target')} = {{ CreatedOnToolsVersion = 26.0; }}; }}; }}; buildConfigurationList = {ident('project-configs')}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {ident('root-group')}; packageReferences = ({ident('local-package')},{ident('dictation-package')}); productRefGroup = {ident('products')}; projectDirPath = \"\"; projectRoot = \"\"; targets = ({ident('target')},{ident('kbd-target')});")
(PROJECT / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 60;\n\tobjects = {\n" + '\n'.join(objects) + f"\n\t}};\n\trootObject = {ident('project')};\n}}\n")
scheme = PROJECT / "xcshareddata" / "xcschemes"
scheme.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target")}" BuildableName="Harness.app" BlueprintName="Harness" ReferencedContainer="container:Harness.xcodeproj"/>'
(scheme / "Harness.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><Testables/></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(f"Generated {PROJECT.relative_to(ROOT)}: Harness ({len(sources)} Swift files) and HarnessKeyboard ({len(kbd_sources)})")
