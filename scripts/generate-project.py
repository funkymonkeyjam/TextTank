#!/usr/bin/env python3
"""Deterministic dependency-free native Xcode project writer."""
from pathlib import Path
import hashlib
import json
import os
from build_config import load_identity
from core_sources import CORE_SOURCES

ROOT = Path(__file__).resolve().parents[1]


def resource_paths(root):
    paths = ['Resources/AutomationTemplates/recipe-ingredient-cleanup.rules.json', 'Resources/AutomationTemplates/sort-unique-lines.rules.json', 'Resources/AutomationTemplates/trim-and-remove-empty-lines.rules.json', 'Resources/Brand/Inter-OFL.txt', 'Resources/Brand/SpaceGrotesk-OFL.txt', 'Resources/Credits.rtf', 'Resources/LanguageProfiles.json', 'Resources/Localizable.xcstrings', 'Resources/TextTank-License.txt', 'Resources/TextTank-User-Guide.txt', 'Resources/TextTank-Welcome.txt', 'Resources/TextTank.icns', 'Resources/boost-License.txt', 'Resources/lexilla-License.txt', 'Resources/scintilla-License.txt']
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
    search_builds = []
    editor_builds = []
    core_builds = []
    runtime_builds = []
    header_refs = {}
    cxx_flags = ' '.join(Path('scripts/user-lexer-flags.txt').read_text().split())
    for path in sorted([*Path('Sources').rglob('*.swift'), *Path('Sources').rglob('*.mm'), *Path('Sources').rglob('*.cxx')]):
        f = add(str(path), 'PBXFileReference', lastKnownFileType={'.swift': 'sourcecode.swift', '.cxx': 'sourcecode.cpp.cpp'}.get(path.suffix, 'sourcecode.cpp.objcpp'), path=str(path), sourceTree='<group>')
        files.append(f)
        destination = (search_builds if str(path) == 'Sources/Search/TTSearchEngine.mm' else
                       editor_builds if str(path) in ['Sources/EditorBridge/TTEditor.mm', 'Sources/Languages/LexUserPort/LexUser.cxx'] else
                       core_builds if str(path) in CORE_SOURCES else
                       runtime_builds if path.suffix == '.swift' and str(path) != 'Sources/TextTankApp/TextTankMain.swift' else builds)
        destination.append(add('build:' + str(path), 'PBXBuildFile', fileRef=f, **{'settings': {'COMPILER_FLAGS': cxx_flags}} if path.suffix == '.cxx' else {}))
    for path in sorted(Path('Sources').rglob('*.h')):
        header_refs[str(path)] = add(str(path), 'PBXFileReference', lastKnownFileType='sourcecode.c.h', path=str(path), sourceTree='<group>')
        files.append(header_refs[str(path)])
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
    search_product = add('NativeSearch:product', 'PBXFileReference', explicitFileType='wrapper.framework', path='NativeSearch.framework', sourceTree='BUILT_PRODUCTS_DIR')
    editor_product = add('EditorBridge:product', 'PBXFileReference', explicitFileType='wrapper.framework', path='EditorBridge.framework', sourceTree='BUILT_PRODUCTS_DIR')
    core_product = add('TextTankCore:product', 'PBXFileReference', explicitFileType='wrapper.framework', path='TextTankCore.framework', sourceTree='BUILT_PRODUCTS_DIR')
    runtime_product = add('TextTankRuntime:product', 'PBXFileReference', explicitFileType='wrapper.framework', path='TextTankRuntime.framework', sourceTree='BUILT_PRODUCTS_DIR')
    products = add('products', 'PBXGroup', children=[product, search_product, editor_product, core_product, runtime_product], name='Products', sourceTree='<group>')
    group = add('root', 'PBXGroup', children=files + [products], sourceTree='<group>')
    sources = add('sources', 'PBXSourcesBuildPhase', buildActionMask='2147483647', files=builds, runOnlyForDeploymentPostprocessing='0')
    res = add('resources', 'PBXResourcesBuildPhase', buildActionMask='2147483647', files=resources, runOnlyForDeploymentPostprocessing='0')
    link = add('link', 'PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[add('linkframework', 'PBXBuildFile', fileRef=framework), add('NativeSearch:app-link', 'PBXBuildFile', fileRef=search_product), add('EditorBridge:app-link', 'PBXBuildFile', fileRef=editor_product), add('TextTankCore:app-link', 'PBXBuildFile', fileRef=core_product), add('TextTankRuntime:app-link', 'PBXBuildFile', fileRef=runtime_product)], runOnlyForDeploymentPostprocessing='0')
    embed = add('embed', 'PBXCopyFilesBuildPhase', buildActionMask='2147483647', dstPath='', dstSubfolderSpec='10', files=[add('embedframework', 'PBXBuildFile', fileRef=framework, settings={'ATTRIBUTES': ['RemoveHeadersOnCopy']}), add('NativeSearch:app-embed', 'PBXBuildFile', fileRef=search_product, settings={'ATTRIBUTES': ['RemoveHeadersOnCopy']}), add('EditorBridge:app-embed', 'PBXBuildFile', fileRef=editor_product, settings={'ATTRIBUTES': ['RemoveHeadersOnCopy']}), add('TextTankCore:app-embed', 'PBXBuildFile', fileRef=core_product, settings={'ATTRIBUTES': ['RemoveHeadersOnCopy']}), add('TextTankRuntime:app-embed', 'PBXBuildFile', fileRef=runtime_product, settings={'ATTRIBUTES': ['RemoveHeadersOnCopy']})], runOnlyForDeploymentPostprocessing='0')
    settings = {'PRODUCT_NAME': 'TextTank',
     'PRODUCT_BUNDLE_IDENTIFIER': 'app.texttank.editor',
     'INFOPLIST_FILE': 'Resources/Info.plist',
     'MACOSX_DEPLOYMENT_TARGET': identity['deploymentTarget'],
     'SWIFT_VERSION': '5.0',
     'SWIFT_STRICT_CONCURRENCY': 'complete',
     'SWIFT_TREAT_WARNINGS_AS_ERRORS': 'YES',
     'OTHER_SWIFT_FLAGS': ['$(inherited)', '-package-name', 'TextTank'],
     'CLANG_CXX_LANGUAGE_STANDARD': 'c++17',
     'CLANG_ENABLE_OBJC_ARC': 'YES',
     'FRAMEWORK_SEARCH_PATHS': ['$(inherited)', '$(PROJECT_DIR)/build/vendor/$(CONFIGURATION)'],
     'HEADER_SEARCH_PATHS': ['$(PROJECT_DIR)/Sources/Search/Boost',
                             '$(PROJECT_DIR)/Vendor/lexilla/lexlib',
                             '$(PROJECT_DIR)/Vendor/scintilla/include',
                             '$(PROJECT_DIR)/Vendor/scintilla/cocoa',
                             '$(PROJECT_DIR)/Vendor/lexilla/include'],
     'OTHER_LDFLAGS': ['$(inherited)', '-lc++'],
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
    search_sources = add('NativeSearch:sources', 'PBXSourcesBuildPhase', buildActionMask='2147483647', files=search_builds, runOnlyForDeploymentPostprocessing='0')
    search_public_headers = [add('NativeSearch:public-header', 'PBXBuildFile', fileRef=header_refs['Sources/Search/TTSearchEngine.h'], settings={'ATTRIBUTES': ['Public']})] if 'Sources/Search/TTSearchEngine.h' in header_refs else []
    search_headers = add('NativeSearch:headers', 'PBXHeadersBuildPhase', buildActionMask='2147483647', files=search_public_headers, runOnlyForDeploymentPostprocessing='0')
    search_link = add('NativeSearch:link', 'PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[], runOnlyForDeploymentPostprocessing='0')
    editor_sources = add('EditorBridge:sources', 'PBXSourcesBuildPhase', buildActionMask='2147483647', files=editor_builds, runOnlyForDeploymentPostprocessing='0')
    editor_public_headers = [add('EditorBridge:public-header', 'PBXBuildFile', fileRef=header_refs['Sources/EditorBridge/TTEditor.h'], settings={'ATTRIBUTES': ['Public']})] if 'Sources/EditorBridge/TTEditor.h' in header_refs else []
    editor_headers = add('EditorBridge:headers', 'PBXHeadersBuildPhase', buildActionMask='2147483647', files=editor_public_headers, runOnlyForDeploymentPostprocessing='0')
    editor_link = add('EditorBridge:link', 'PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[add('EditorBridge:scintilla-link', 'PBXBuildFile', fileRef=framework)], runOnlyForDeploymentPostprocessing='0')
    core_sources = add('TextTankCore:sources', 'PBXSourcesBuildPhase', buildActionMask='2147483647', files=core_builds, runOnlyForDeploymentPostprocessing='0')
    core_link = add('TextTankCore:link', 'PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[add('TextTankCore:native-search-link', 'PBXBuildFile', fileRef=search_product)], runOnlyForDeploymentPostprocessing='0')
    runtime_sources = add('TextTankRuntime:sources', 'PBXSourcesBuildPhase', buildActionMask='2147483647', files=runtime_builds, runOnlyForDeploymentPostprocessing='0')
    runtime_link = add('TextTankRuntime:link', 'PBXFrameworksBuildPhase', buildActionMask='2147483647', files=[add('TextTankRuntime:core-link', 'PBXBuildFile', fileRef=core_product), add('TextTankRuntime:bridge-link', 'PBXBuildFile', fileRef=editor_product), add('TextTankRuntime:search-link', 'PBXBuildFile', fileRef=search_product)], runOnlyForDeploymentPostprocessing='0')
    runtime_configs = []
    core_configs = []
    editor_configs = []
    search_configs = []
    configs = []
    pconfigs = []
    for name in ['Debug', 'Release']:
        configs.append(add('config' + name, 'XCBuildConfiguration', name=name, buildSettings={**settings, **({'SWIFT_OPTIMIZATION_LEVEL': '-O', 'GCC_OPTIMIZATION_LEVEL': '3', 'DEBUG_INFORMATION_FORMAT': 'dwarf-with-dsym', 'ENABLE_TESTABILITY': 'NO'} if name == 'Release' else {'SWIFT_OPTIMIZATION_LEVEL': '-Onone', 'GCC_OPTIMIZATION_LEVEL': '0', 'GCC_PREPROCESSOR_DEFINITIONS': ['$(inherited)', 'DEBUG=1'], 'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'DEBUG', 'ONLY_ACTIVE_ARCH': 'YES', 'ENABLE_TESTABILITY': 'YES'})}))
        search_settings = {**settings, 'PRODUCT_NAME': 'NativeSearch', 'PRODUCT_MODULE_NAME': 'NativeSearch', 'PRODUCT_BUNDLE_IDENTIFIER': 'app.texttank.NativeSearch', 'DEFINES_MODULE': 'YES', 'GENERATE_INFOPLIST_FILE': 'YES', 'MODULEMAP_FILE': 'Sources/Search/module.modulemap', 'SKIP_INSTALL': 'YES', 'LD_DYLIB_INSTALL_NAME': '@rpath/$(EXECUTABLE_PATH)', 'HEADER_SEARCH_PATHS': ['$(PROJECT_DIR)/Sources/Search/Boost'], 'FRAMEWORK_SEARCH_PATHS': ['$(inherited)'], 'SWIFT_OPTIMIZATION_LEVEL': '-O' if name == 'Release' else '-Onone', 'OTHER_LDFLAGS': ['$(inherited)', '-framework', 'Foundation', '-lc++'], 'GCC_OPTIMIZATION_LEVEL': '3' if name == 'Release' else '0'}
        for key in ['INFOPLIST_FILE', 'SWIFT_OBJC_BRIDGING_HEADER']:
            search_settings.pop(key, None)
        if name == 'Debug':
            search_settings['GCC_PREPROCESSOR_DEFINITIONS'] = ['$(inherited)', 'DEBUG=1']
        search_configs.append(add('NativeSearch:config:' + name, 'XCBuildConfiguration', name=name, buildSettings=search_settings))
        editor_settings = {**settings, 'PRODUCT_NAME': 'EditorBridge', 'PRODUCT_MODULE_NAME': 'EditorBridge', 'PRODUCT_BUNDLE_IDENTIFIER': 'app.texttank.EditorBridge', 'DEFINES_MODULE': 'YES', 'GENERATE_INFOPLIST_FILE': 'YES', 'MODULEMAP_FILE': 'Sources/EditorBridge/module.modulemap', 'SKIP_INSTALL': 'YES', 'LD_DYLIB_INSTALL_NAME': '@rpath/$(EXECUTABLE_PATH)', 'OTHER_LDFLAGS': ['$(inherited)', '$(PROJECT_DIR)/build/vendor/$(CONFIGURATION)/liblexilla.a', '-framework', 'Cocoa', '-lc++'], 'SWIFT_OPTIMIZATION_LEVEL': '-O' if name == 'Release' else '-Onone', 'GCC_OPTIMIZATION_LEVEL': '3' if name == 'Release' else '0'}
        editor_settings['HEADER_SEARCH_PATHS'] = [value for value in settings['HEADER_SEARCH_PATHS'] if '/Sources/Search/' not in value]
        for key in ['INFOPLIST_FILE', 'SWIFT_OBJC_BRIDGING_HEADER']:
            editor_settings.pop(key, None)
        if name == 'Debug':
            editor_settings['GCC_PREPROCESSOR_DEFINITIONS'] = ['$(inherited)', 'DEBUG=1']
        editor_configs.append(add('EditorBridge:config:' + name, 'XCBuildConfiguration', name=name, buildSettings=editor_settings))
        core_settings = {**settings, 'PRODUCT_NAME': 'TextTankCore', 'PRODUCT_MODULE_NAME': 'TextTankCore', 'PRODUCT_BUNDLE_IDENTIFIER': 'app.texttank.Core', 'DEFINES_MODULE': 'YES', 'GENERATE_INFOPLIST_FILE': 'YES', 'SKIP_INSTALL': 'YES', 'LD_DYLIB_INSTALL_NAME': '@rpath/$(EXECUTABLE_PATH)', 'HEADER_SEARCH_PATHS': [], 'FRAMEWORK_SEARCH_PATHS': ['$(inherited)'], 'OTHER_LDFLAGS': ['$(inherited)', '-lz'], 'SWIFT_OPTIMIZATION_LEVEL': '-O' if name == 'Release' else '-Onone', 'ENABLE_TESTABILITY': 'NO' if name == 'Release' else 'YES'}
        core_settings.pop('INFOPLIST_FILE', None)
        if name == 'Debug':
            core_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        core_configs.append(add('TextTankCore:config:' + name, 'XCBuildConfiguration', name=name, buildSettings=core_settings))
        runtime_settings = {**settings, 'PRODUCT_NAME': 'TextTankRuntime', 'PRODUCT_MODULE_NAME': 'TextTankRuntime', 'PRODUCT_BUNDLE_IDENTIFIER': 'app.texttank.Runtime', 'DEFINES_MODULE': 'YES', 'GENERATE_INFOPLIST_FILE': 'YES', 'SKIP_INSTALL': 'YES', 'LD_DYLIB_INSTALL_NAME': '@rpath/$(EXECUTABLE_PATH)', 'OTHER_LDFLAGS': ['$(inherited)', '-lc++'], 'SWIFT_OPTIMIZATION_LEVEL': '-O' if name == 'Release' else '-Onone', 'ENABLE_TESTABILITY': 'NO' if name == 'Release' else 'YES'}
        runtime_settings.pop('INFOPLIST_FILE', None)
        if name == 'Debug':
            runtime_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG'
        runtime_configs.append(add('TextTankRuntime:config:' + name, 'XCBuildConfiguration', name=name, buildSettings=runtime_settings))
        pconfigs.append(add('pconfig' + name, 'XCBuildConfiguration', name=name, buildSettings={'SDKROOT': 'macosx', 'ARCHS': identity['architecture']}))
    cl = add('configs', 'XCConfigurationList', buildConfigurations=configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')
    pcl = add('pconfigs', 'XCConfigurationList', buildConfigurations=pconfigs, defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')
    search_cl = add('NativeSearch:configs', 'XCConfigurationList', buildConfigurations=search_configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')
    search_target = add('NativeSearch:target', 'PBXNativeTarget', buildConfigurationList=search_cl, buildPhases=[search_sources, search_headers, search_link], buildRules=[], dependencies=[], name='NativeSearch', productName='NativeSearch', productReference=search_product, productType='com.apple.product-type.framework')
    search_dependency = add('NativeSearch:app-dependency', 'PBXTargetDependency', target=search_target)
    editor_cl = add('EditorBridge:configs', 'XCConfigurationList', buildConfigurations=editor_configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')
    editor_target = add('EditorBridge:target', 'PBXNativeTarget', buildConfigurationList=editor_cl, buildPhases=[editor_sources, editor_headers, editor_link], buildRules=[], dependencies=[], name='EditorBridge', productName='EditorBridge', productReference=editor_product, productType='com.apple.product-type.framework')
    editor_dependency = add('EditorBridge:app-dependency', 'PBXTargetDependency', target=editor_target)
    core_cl = add('TextTankCore:configs', 'XCConfigurationList', buildConfigurations=core_configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')
    core_dependency = add('TextTankCore:search-dependency', 'PBXTargetDependency', target=search_target)
    core_target = add('TextTankCore:target', 'PBXNativeTarget', buildConfigurationList=core_cl, buildPhases=[core_sources, core_link], buildRules=[], dependencies=[core_dependency], name='TextTankCore', productName='TextTankCore', productReference=core_product, productType='com.apple.product-type.framework')
    app_core_dependency = add('TextTankCore:app-dependency', 'PBXTargetDependency', target=core_target)
    runtime_cl = add('TextTankRuntime:configs', 'XCConfigurationList', buildConfigurations=runtime_configs, defaultConfigurationIsVisible='0', defaultConfigurationName='Debug')
    runtime_dependencies = [add('TextTankRuntime:dependency:' + name, 'PBXTargetDependency', target=value) for name, value in [('Core', core_target), ('EditorBridge', editor_target), ('NativeSearch', search_target)]]
    runtime_target = add('TextTankRuntime:target', 'PBXNativeTarget', buildConfigurationList=runtime_cl, buildPhases=[runtime_sources, runtime_link], buildRules=[], dependencies=runtime_dependencies, name='TextTankRuntime', productName='TextTankRuntime', productReference=runtime_product, productType='com.apple.product-type.framework')
    app_runtime_dependency = add('TextTankRuntime:app-dependency', 'PBXTargetDependency', target=runtime_target)
    target = add('target', 'PBXNativeTarget', buildConfigurationList=cl, buildPhases=[sources, link, res, embed], buildRules=[], dependencies=[search_dependency, editor_dependency, app_core_dependency, app_runtime_dependency], name='TextTank', productName='TextTank', productReference=product, productType='com.apple.product-type.application')
    project = add('project', 'PBXProject', attributes={'LastUpgradeCheck': '1600'}, buildConfigurationList=pcl, compatibilityVersion='Xcode 14.0', developmentRegion='en', hasScannedForEncodings='0', knownRegions=['en', 'Base'], mainGroup=group, productRefGroup=products, projectDirPath='', projectRoot='', targets=[target, search_target, editor_target, core_target, runtime_target])
    Path('TextTank.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n' + q({'archiveVersion': 1, 'classes': {}, 'objectVersion': 56, 'objects': objects, 'rootObject': project}) + '\n')
    Path('TextTank.xcodeproj/xcshareddata/xcschemes/TextTank.xcscheme').write_text(f'<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="TextTank.app" BlueprintName="TextTank" ReferencedContainer="container:TextTank.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="TextTank.app" BlueprintName="TextTank" ReferencedContainer="container:TextTank.xcodeproj"/></BuildableProductRunnable></LaunchAction></Scheme>')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError) as error:
        raise SystemExit(f'Project generation stopped: {error}')
