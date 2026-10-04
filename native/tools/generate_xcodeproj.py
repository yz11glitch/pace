"""Generate native/Pace.xcodeproj (deterministic IDs, synchronized folders).

Usage: python3 native/tools/generate_xcodeproj.py

Sources live in synchronized folders (PaceApp/, PaceUITests/), so adding a
Swift file needs no project edit. Re-run only to change targets or settings.
"""

from __future__ import annotations

import hashlib
from pathlib import Path

NATIVE = Path(__file__).resolve().parents[1]


def oid(name: str) -> str:
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()


I = {name: oid(name) for name in [
    "project", "main", "products", "config-group", "config-ref", "entitlements-ref", "app-sync", "uitest-sync",
    "app", "uitest", "app-product", "uitest-product", "app-sources", "app-frameworks", "app-resources",
    "uitest-sources", "uitest-frameworks", "uitest-resources", "uitest-dep", "uitest-proxy",
    "core-ref", "store-ref", "core-prod", "store-prod", "core-build", "store-build",
    "project-configs", "app-configs", "uitest-configs", "project-debug", "project-release",
    "app-debug", "app-release", "uitest-debug", "uitest-release",
]}

COMMON = """\
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 26.0;
				LOCALIZATION_PREFERS_STRING_CATALOGS = YES;
				SDKROOT = iphoneos;
				SWIFT_VERSION = 6.0;"""

APP = """\
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_ENTITLEMENTS = Config/PaceApp.entitlements;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_CFBundleDisplayName = Pace;
				INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO;
				INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.finance";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = "$(PACE_BUNDLE_ID_PREFIX).pace";
				PRODUCT_NAME = "$(TARGET_NAME)";
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SUPPORTS_MACCATALYST = NO;
				SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
				SWIFT_EMIT_LOC_STRINGS = YES;
				TARGETED_DEVICE_FAMILY = 1;"""

UITEST = """\
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = "$(PACE_BUNDLE_ID_PREFIX).pace.uitests";
				PRODUCT_NAME = "$(TARGET_NAME)";
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				TARGETED_DEVICE_FAMILY = 1;
				TEST_TARGET_NAME = Pace;"""


def config(key: str, name: str, body: str, base: str | None = None, debug: bool = True) -> str:
    extra = "\n\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;\n\t\t\t\tONLY_ACTIVE_ARCH = YES;\n\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG $(inherited)\";" if debug \
        else "\n\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";\n\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;\n\t\t\t\tVALIDATE_PRODUCT = YES;"
    base_line = f"\n\t\t\tbaseConfigurationReference = {I['config-ref']} /* Pace.xcconfig */;" if base else ""
    body = body + (extra if key.startswith("project") else "")
    return f"""\t\t{I[key]} /* {name} */ = {{
\t\t\tisa = XCBuildConfiguration;{base_line}
\t\t\tbuildSettings = {{
{body}
\t\t\t}};
\t\t\tname = {name};
\t\t}};"""


def build() -> str:
    return f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXBuildFile section */
		{I['core-build']} /* PaceCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {I['core-prod']} /* PaceCore */; }};
		{I['store-build']} /* PaceStore in Frameworks */ = {{isa = PBXBuildFile; productRef = {I['store-prod']} /* PaceStore */; }};
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
		{I['uitest-proxy']} /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = {I['project']} /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = {I['app']};
			remoteInfo = Pace;
		}};
/* End PBXContainerItemProxy section */

/* Begin PBXFileReference section */
		{I['app-product']} /* Pace.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Pace.app; sourceTree = BUILT_PRODUCTS_DIR; }};
		{I['uitest-product']} /* PaceUITests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = PaceUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};
		{I['config-ref']} /* Pace.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Pace.xcconfig; sourceTree = "<group>"; }};
		{I['entitlements-ref']} /* PaceApp.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = PaceApp.entitlements; sourceTree = "<group>"; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		{I['app-sync']} /* PaceApp */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = PaceApp; sourceTree = "<group>"; }};
		{I['uitest-sync']} /* PaceUITests */ = {{isa = PBXFileSystemSynchronizedRootGroup; path = PaceUITests; sourceTree = "<group>"; }};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		{I['app-frameworks']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{I['core-build']} /* PaceCore in Frameworks */,
				{I['store-build']} /* PaceStore in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{I['uitest-frameworks']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{I['main']} = {{
			isa = PBXGroup;
			children = (
				{I['config-group']} /* Config */,
				{I['app-sync']} /* PaceApp */,
				{I['uitest-sync']} /* PaceUITests */,
				{I['products']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{I['config-group']} /* Config */ = {{
			isa = PBXGroup;
			children = (
				{I['config-ref']} /* Pace.xcconfig */,
				{I['entitlements-ref']} /* PaceApp.entitlements */,
			);
			path = Config;
			sourceTree = "<group>";
		}};
		{I['products']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{I['app-product']} /* Pace.app */,
				{I['uitest-product']} /* PaceUITests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{I['app']} /* Pace */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {I['app-configs']} /* Build configuration list for PBXNativeTarget "Pace" */;
			buildPhases = (
				{I['app-sources']} /* Sources */,
				{I['app-frameworks']} /* Frameworks */,
				{I['app-resources']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{I['app-sync']} /* PaceApp */,
			);
			name = Pace;
			packageProductDependencies = (
				{I['core-prod']} /* PaceCore */,
				{I['store-prod']} /* PaceStore */,
			);
			productName = Pace;
			productReference = {I['app-product']} /* Pace.app */;
			productType = "com.apple.product-type.application";
		}};
		{I['uitest']} /* PaceUITests */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {I['uitest-configs']} /* Build configuration list for PBXNativeTarget "PaceUITests" */;
			buildPhases = (
				{I['uitest-sources']} /* Sources */,
				{I['uitest-frameworks']} /* Frameworks */,
				{I['uitest-resources']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
				{I['uitest-dep']} /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				{I['uitest-sync']} /* PaceUITests */,
			);
			name = PaceUITests;
			productName = PaceUITests;
			productReference = {I['uitest-product']} /* PaceUITests.xctest */;
			productType = "com.apple.product-type.bundle.ui-testing";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{I['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2700;
				LastUpgradeCheck = 2700;
				TargetAttributes = {{
					{I['app']} = {{
						CreatedOnToolsVersion = 27.0;
					}};
					{I['uitest']} = {{
						CreatedOnToolsVersion = 27.0;
						TestTargetID = {I['app']};
					}};
				}};
			}};
			buildConfigurationList = {I['project-configs']} /* Build configuration list for PBXProject "Pace" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {I['main']};
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				{I['core-ref']} /* XCLocalSwiftPackageReference "Packages/PaceCore" */,
				{I['store-ref']} /* XCLocalSwiftPackageReference "Packages/PaceStore" */,
			);
			preferredProjectObjectVersion = 77;
			productRefGroup = {I['products']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{I['app']} /* Pace */,
				{I['uitest']} /* PaceUITests */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{I['app-resources']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{I['uitest-resources']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{I['app-sources']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{I['uitest-sources']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
		{I['uitest-dep']} /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			target = {I['app']} /* Pace */;
			targetProxy = {I['uitest-proxy']} /* PBXContainerItemProxy */;
		}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
{config('project-debug', 'Debug', COMMON)}
{config('project-release', 'Release', COMMON, debug=False)}
{config('app-debug', 'Debug', APP, base='xcconfig')}
{config('app-release', 'Release', APP, base='xcconfig')}
{config('uitest-debug', 'Debug', UITEST, base='xcconfig')}
{config('uitest-release', 'Release', UITEST, base='xcconfig')}
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{I['project-configs']} /* Build configuration list for PBXProject "Pace" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{I['project-debug']} /* Debug */,
				{I['project-release']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{I['app-configs']} /* Build configuration list for PBXNativeTarget "Pace" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{I['app-debug']} /* Debug */,
				{I['app-release']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{I['uitest-configs']} /* Build configuration list for PBXNativeTarget "PaceUITests" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{I['uitest-debug']} /* Debug */,
				{I['uitest-release']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		{I['core-ref']} /* XCLocalSwiftPackageReference "Packages/PaceCore" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = Packages/PaceCore;
		}};
		{I['store-ref']} /* XCLocalSwiftPackageReference "Packages/PaceStore" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = Packages/PaceStore;
		}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		{I['core-prod']} /* PaceCore */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {I['core-ref']} /* XCLocalSwiftPackageReference "Packages/PaceCore" */;
			productName = PaceCore;
		}};
		{I['store-prod']} /* PaceStore */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {I['store-ref']} /* XCLocalSwiftPackageReference "Packages/PaceStore" */;
			productName = PaceStore;
		}};
/* End XCSwiftPackageProductDependency section */
	}};
	rootObject = {I['project']} /* Project object */;
}}
"""


SCHEME = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2700" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{I['app']}" BuildableName = "Pace.app" BlueprintName = "Pace" ReferencedContainer = "container:Pace.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO" parallelizable = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{I['uitest']}" BuildableName = "PaceUITests.xctest" BlueprintName = "PaceUITests" ReferencedContainer = "container:Pace.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{I['app']}" BuildableName = "Pace.app" BlueprintName = "Pace" ReferencedContainer = "container:Pace.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{I['app']}" BuildableName = "Pace.app" BlueprintName = "Pace" ReferencedContainer = "container:Pace.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""

if __name__ == "__main__":
    project = NATIVE / "Pace.xcodeproj"
    (project / "xcshareddata" / "xcschemes").mkdir(parents=True, exist_ok=True)
    (project / "project.pbxproj").write_text(build(), encoding="utf-8")
    (project / "xcshareddata" / "xcschemes" / "Pace.xcscheme").write_text(SCHEME, encoding="utf-8")
    print(f"wrote {project}")
