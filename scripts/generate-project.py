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

sources = sorted((IOS / "Harness").glob("*.swift"))
assert sources, "No app sources"
resources = [IOS / "Harness" / "Assets.xcassets", IOS / "Harness" / "PrivacyInfo.xcprivacy"]
for path in sources + resources + [IOS / "Harness" / "Info.plist"]:
    kind = "sourcecode.swift" if path.suffix == ".swift" else "folder.assetcatalog" if path.suffix == ".xcassets" else "text.plist.xml"
    obj("file:" + path.name, f"isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(path.name)}; sourceTree = \"<group>\";")
for path in sources + resources:
    obj("build:" + path.name, f"isa = PBXBuildFile; fileRef = {ident('file:' + path.name)};")
obj("app", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Harness.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj("group-app", f"isa = PBXGroup; children = ({','.join(ident('file:' + p.name) for p in sources + resources + [IOS / 'Harness' / 'Info.plist'])}); path = Harness; sourceTree = \"<group>\";")
obj("products", f"isa = PBXGroup; children = ({ident('app')}); name = Products; sourceTree = \"<group>\";")
obj("root-group", f"isa = PBXGroup; children = ({ident('group-app')},{ident('products')}); sourceTree = \"<group>\";")
obj("sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(ident('build:' + p.name) for p in sources)}); runOnlyForDeploymentPostprocessing = 0;")
obj("resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({','.join(ident('build:' + p.name) for p in resources)}); runOnlyForDeploymentPostprocessing = 0;")
obj("local-package", 'isa = XCLocalSwiftPackageReference; relativePath = ..;')
obj("core-product", f"isa = XCSwiftPackageProductDependency; package = {ident('local-package')}; productName = HarnessCore;")
obj("core-build", f"isa = PBXBuildFile; productRef = {ident('core-product')};")
obj("frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({ident('core-build')}); runOnlyForDeploymentPostprocessing = 0;")

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
        "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks", "MARKETING_VERSION": "0.1.0", "CURRENT_PROJECT_VERSION": "1",
    }
    for kind, settings in [("project", common), ("target", app)]:
        values = ' '.join(f"{key} = {quote(value)};" for key, value in settings.items())
        obj(f"{kind}-{mode}", f"isa = XCBuildConfiguration; buildSettings = {{ {values} }}; name = {mode};")
for kind in ["project", "target"]:
    obj(f"{kind}-configs", f"isa = XCConfigurationList; buildConfigurations = ({ident(kind + '-Debug')},{ident(kind + '-Release')}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
obj("target", f"isa = PBXNativeTarget; buildConfigurationList = {ident('target-configs')}; buildPhases = ({ident('sources')},{ident('frameworks')},{ident('resources')}); buildRules = (); dependencies = (); name = Harness; packageProductDependencies = ({ident('core-product')}); productName = Harness; productReference = {ident('app')}; productType = \"com.apple.product-type.application\";")
obj("project", f"isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; TargetAttributes = {{ {ident('target')} = {{ CreatedOnToolsVersion = 26.0; }}; }}; }}; buildConfigurationList = {ident('project-configs')}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base); mainGroup = {ident('root-group')}; packageReferences = ({ident('local-package')}); productRefGroup = {ident('products')}; projectDirPath = \"\"; projectRoot = \"\"; targets = ({ident('target')});")
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
print(f"Generated {PROJECT.relative_to(ROOT)} with {len(sources)} Swift files")
