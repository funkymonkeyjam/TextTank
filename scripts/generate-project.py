#!/usr/bin/env python3
"""Deterministic dependency-free native Xcode project writer."""
from pathlib import Path
import hashlib
import json
import os
from build_config import load_identity

ROOT = Path(__file__).resolve().parents[1]


def resource_paths(root):
    paths = ['Resources/AutomationTemplates/recipe-ingredient-cleanup.rules.json', 'Resources/AutomationTemplates/sort-unique-lines.rules.json', 'Resources/AutomationTemplates/trim-and-remove-empty-lines.rules.json', 'Resources/Brand/Inter-OFL.txt', 'Resources/Brand/SpaceGrotesk-OFL.txt', 'Resources/Credits.rtf', 'Resources/LanguageProfiles.json', 'Resources/Localizable.xcstrings', 'Resources/TextTank-License.txt', 'Resources/TextTank.icns', 'Resources/boost-License.txt', 'Resources/lexilla-License.txt', 'Resources/scintilla-License.txt']
    for path in paths:
        if not (root / path).is_file():
            raise ValueError(f"Required bundled resource missing: {path}")
    return paths

objects = {}

def uid(s):
    return hashlib.sha1(s.encode()).hexdigest()[:24].upper()

def add(key, isa, **fields):
    i = uid(key)
    objects[i] = {'isa': isa, **fields}
    return i

def q(x):
    if isinstance(x, dict):
        return '{ ' + ' '.join((f'{json.dumps(k)} = {q(v)};' for (k, v) in x.items())) + ' }'
    if isinstance(x, list):
        return '(' + ', '.join((q(v) for v in x)) + ')'
    return json.dumps(str(x))
def main():
    objects.clear()
    os.chdir(ROOT)
    identity = load_identity(ROOT)
    files = []
    builds = []
    cxx_flags = ' '.join(Path('scripts/user-lexer-flags.txt').read_text().split())
    for path in sorted([*Path('Sources').rglob('*.swift'), *Path('Sources').rglob('*.mm'), *Path('Sources').rglob('*.cxx')]):
        f = add(str(path), 'PBXFileReference', lastKnownFileType={'.swift': 'sourcecode.swift', '.cxx': 'sourcecode.cpp.cpp'}.get(path.suffix, 'sourcecode.cpp.objcpp'), path=str(path), sourceTree='<group>')
        files.append(f)
        builds.append(add('build:' + str(path), 'PBXBuildFile', fileRef=f, **{'settings': {'COMPILER_FLAGS': cxx_flags}} if path.suffix == '.cxx' else {}))
    for path in sorted(Path('Sources').rglob('*.h')):
        files.append(add(str(path), 'PBXFileReference', lastKnownFileType='sourcecode.c.h', path=str(path), sourceTree='<group>'))
    resources = []
    for relative in resource_paths(ROOT):
        path = Path(relative)
        if path.is_file():
            f = add(str(path), 'PBXFileReference', lastKnownFileType='text.json.xcstrings' if path.suffix == '.xcstrings' else 'file', path=str(path), sourceTree='<group>')
            files.append(f)
            resources.append(add('build:' + str(path), 'PBXBuildFile', fileRef=f))
    framework = add('framework', 'PBXFileReference', lastKnownFileType='wrapper.framework', path='build/vendor/$(CONFIGURATION)/Scintilla.framework', sourceTree='<group>')
    files.append(framework)
    product = add('product', 'PBXFileReference', explicitFileType='wrapper.application', path='TextTank.app', sourceTree='BUILT_PRODUCTS_DIR')
    products = add('products', 'PBXGroup', children=[product], name='Products', sourceTree='<group>')
    group = add('root', 'PBXGroup', children=files + [products], sourceTree='<group>')
    sources = add('sources', 'PBXSourcesBuildPhase', buildActionMask='2147483647', files=builds, runOnlyForDeploymentPostprocessing='0')
    res = add('resources', 'PBXResourcesBuildPhase', buildActionMask='2147483647', files=resources, runOnlyForDeploymentPostprocessing='0')
    link = add('link', 'PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[add('linkframework', 'PBXBuildFile', fileRef=framework)], runOnlyForDeploymentPostprocessing='0')
    embed = add('embed', 'PBXCopyFilesBuildPhase', buildActionMask='2147483647', dstPath='', dstSubfolderSpec='10', files=[add('embedframework', 'PBXBuildFile', fileRef=framework, settings={'ATTRIBUTES': ['RemoveHeadersOnCopy']})], runOnlyForDeploymentPostprocessing='0')
    settings = {'PRODUCT_NAME': 'TextTank',
     'PRODUCT_BUNDLE_IDENTIFIER': 'app.texttank.editor',
     'INFOPLIST_FILE': 'Resources/Info.plist',
     'MACOSX_DEPLOYMENT_TARGET': identity['deploymentTarget'],
     'SWIFT_VERSION': '5.0',
     'SWIFT_TREAT_WARNINGS_AS_ERRORS': 'YES',
     'SWIFT_OBJC_BRIDGING_HEADER': 'Sources/EditorBridge/TTEditor.h',
     'CLANG_CXX_LANGUAGE_STANDARD': 'c++17',
     'CLANG_ENABLE_OBJC_ARC': 'YES',
     'FRAMEWORK_SEARCH_PATHS': ['$(inherited)', '$(PROJECT_DIR)/build/vendor/$(CONFIGURATION)'],
     'HEADER_SEARCH_PATHS': ['$(PROJECT_DIR)/Sources/Search/Boost',
                             '$(PROJECT_DIR)/Vendor/lexilla/lexlib',
                             '$(PROJECT_DIR)/Vendor/scintilla/include',
                             '$(PROJECT_DIR)/Vendor/scintilla/cocoa',
                             '$(PROJECT_DIR)/Vendor/lexilla/include'],
     'OTHER_LDFLAGS': ['$(inherited)',
                       '$(PROJECT_DIR)/build/vendor/$(CONFIGURATION)/liblexilla.a',
                       '-lc++'],
     'LD_RUNPATH_SEARCH_PATHS': ['$(inherited)', '@executable_path/../Frameworks'],
     'CODE_SIGNING_ALLOWED': 'NO',
     'SWIFT_OPTIMIZATION_LEVEL': '-Onone',
     'CLANG_MODULE_CACHE_PATH': '$(PROJECT_DIR)/build/ModuleCache',
     'SWIFT_MODULE_CACHE_PATH': '$(PROJECT_DIR)/build/ModuleCache',
     'ALWAYS_SEARCH_USER_PATHS': 'NO',
     'CLANG_ANALYZER_NONNULL': 'YES',
     'CLANG_ANALYZER_NUMBER_OBJECT_CONVERSION': 'YES_AGGRESSIVE',
     'CLANG_WARN_BOOL_CONVERSION': 'YES',
     'CLANG_WARN_CONSTANT_CONVERSION': 'YES',
     'CLANG_WARN_EMPTY_BODY': 'YES',
     'CLANG_WARN_ENUM_CONVERSION': 'YES',
     'CLANG_WARN_INFINITE_RECURSION': 'YES',
     'CLANG_WARN_INT_CONVERSION': 'YES',
     'CLANG_WARN_UNREACHABLE_CODE': 'YES',
     'GCC_WARN_64_TO_32_BIT_CONVERSION': 'YES',
     'GCC_WARN_ABOUT_RETURN_TYPE': 'YES',
     'GCC_WARN_UNINITIALIZED_AUTOS': 'YES_AGGRESSIVE',
     'GCC_WARN_UNUSED_VARIABLE': 'YES',
     'DEAD_CODE_STRIPPING': 'YES',
     'ENABLE_STRICT_OBJC_MSGSEND': 'YES'}
    configs = []
    pconfigs = []
    for name in ['Debug', 'Release']:
        configs.append(add('config' + name, 'XCBuildConfiguration', name=name, buildSettings={**settings, **({'SWIFT_OPTIMIZATION_LEVEL': '-O', 'GCC_OPTIMIZATION_LEVEL': '3', 'DEBUG_INFORMATION_FORMAT': 'dwarf-with-dsym', 'ENABLE_TESTABILITY': 'NO'} if name == 'Release' else {'SWIFT_OPTIMIZATION_LEVEL': '-Onone', 'GCC_OPTIMIZATION_LEVEL': '0', 'GCC_PREPROCESSOR_DEFINITIONS': ['$(inherited)', 'DEBUG=1'], 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG', 'ONLY_ACTIVE_ARCH': 'YES', 'ENABLE_TESTABILITY': 'YES'})}))
        pconfigs.append(add('pconfig' + name, 'XCBuildConfiguration', name=name, buildSettings={'SDKROOT': 'macosx', 'ARCHS': identity['architecture']}))
    cl = add('configs', 'XCConfigurationList', buildConfigurations=configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')
    pcl = add('pconfigs', 'XCConfigurationList', buildConfigurations=pconfigs, defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')
    target = add('target', 'PBXNativeTarget', buildConfigurationList=cl, buildPhases=[sources, link, res, embed], buildRules=[], dependencies=[], name='TextTank', productName='TextTank', productReference=product, productType='com.apple.product-type.application')
    project = add('project', 'PBXProject', attributes={'LastUpgradeCheck': '1600'}, buildConfigurationList=pcl, compatibilityVersion='Xcode 14.0', developmentRegion='en', hasScannedForEncodings='0', knownRegions=['en', 'Base'], mainGroup=group, productRefGroup=products, projectDirPath='', projectRoot='', targets=[target])
    Path('TextTank.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n' + q({'archiveVersion': 1, 'classes': {}, 'objectVersion': 56, 'objects': objects, 'rootObject': project}) + '\n')
    Path('TextTank.xcodeproj/xcshareddata/xcschemes/TextTank.xcscheme').write_text(f'<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="TextTank.app" BlueprintName="TextTank" ReferencedContainer="container:TextTank.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="TextTank.app" BlueprintName="TextTank" ReferencedContainer="container:TextTank.xcodeproj"/></BuildableProductRunnable></LaunchAction></Scheme>')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(f'Project generation stopped: {error}')
