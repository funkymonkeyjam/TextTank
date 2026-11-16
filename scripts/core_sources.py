"""Authoritative Foundation Core source membership used by project and check clients."""
CORE_SOURCES = ['Sources/Automations/AutomationCore.swift', 'Sources/Documents/CommentCommands.swift', 'Sources/Documents/EditorCommandCatalog.swift', 'Sources/Documents/EditorCommands.swift', 'Sources/Documents/FailureContext.swift', 'Sources/Documents/FileCodec.swift', 'Sources/Documents/LineOrder.swift', 'Sources/Documents/PrivateFileStore.swift', 'Sources/Documents/RecoveryStore.swift', 'Sources/Documents/RecoveryWriter.swift', 'Sources/Documents/SettingsCore.swift', 'Sources/Documents/Strings.swift', 'Sources/Documents/VersionedLibrary.swift', 'Sources/Languages/LanguageCore.swift', 'Sources/Languages/UserDefinedLanguage.swift', 'Sources/Macros/MacroCore.swift', 'Sources/Run/RunCore.swift', 'Sources/Search/FolderReplacement.swift', 'Sources/Search/FolderSearch.swift', 'Sources/Search/FolderSearchFilters.swift', 'Sources/Search/SearchCore.swift', 'Sources/Search/SearchSession.swift', 'Sources/Utilities/UtilityCore.swift', 'Sources/Workspace/WorkspaceBrowserCore.swift', 'Sources/Workspace/WorkspaceCore.swift']

if __name__ == '__main__':
    from pathlib import Path
    import sys
    if sys.argv[1:] != ['--application-clients']:
        raise SystemExit('Expected --application-clients')
    root = Path(__file__).resolve().parents[1]
    for path in sorted((root / 'Sources').rglob('*.swift')):
        relative = str(path.relative_to(root))
        if relative not in CORE_SOURCES and '/UI/' not in relative:
            print(relative)
