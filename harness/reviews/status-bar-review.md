# Document status bar — 2026-11-15

Added live document name/unsaved indicator, bookmark count, language, one-based caret line and tab-expanded column (including virtual space), Unicode scalar and document-line counts, actual selected-character count, selection count, base font size including zoom, tabs/spaces width, encoding/BOM, actual LF/CRLF/CR/mixed endings, wrapping and read-only state. Empty viewport gutter labels do not affect document counts. Metadata belongs to the focused split. Character counts include line-ending scalars and exclude synthetic multiple-selection clipboard separators.

A separate message row reports successful session-restoration saves or recovery errors. Details appear in subtle rounded boxes aligned to the right; rows wrap when space is limited, and full values remain available via tooltip/accessibility. Existing native light/dark/system colors are preserved. Status badges now open native option menus; no unsupported marker counter is simulated.

Validation: application built; 73 bridge checks and 88 native document assertions passed. Running app visually inspected in dark appearance: blank document shows 0 characters / 1 line; pasting Milk + LF + Eggs updates to 9 characters / 2 lines / Ln 2 Col 5 and unsaved indicator, followed by successful recovery message. No new independent light-mode visual claim.

Independent review identified repeated selected-text copying and artificial separators in multiple-selection counts. Repaired with selection/revision caching and engine character counts across actual ranges, plus an empty-primary-selection Unicode regression check. Virtual-space column support added; font labeled Base to distinguish syntax style overrides. Timer uses weak ownership and is invalidated on close/deinit. Document-wide counts/EOL scanning remains synchronous once per observed revision; very large actively edited documents have not been performance-profiled.

This is still an incomplete preview; no full Notepad++ parity claim.

Presentation follow-up: local build passed; running application visually verified with full readable labels in individual right-aligned boxes. Existing native colors retained. Initial padding truncation found during visual inspection was repaired before packaging. Narrow-window wrapping is implemented but not independently visually verified.

Interactive follow-up: removed outlines and reduced backgrounds to a 3.5% native label-color fill. Badges are accessible native buttons, right-aligned. Encoding offers separate reload and conversion sections limited to supported encodings; reload is disabled on unsaved files and retains the existing discard confirmation. Conversion does not implicitly save. Indentation options apply to the current view, with a separate default-settings action. Other menus cover language, line endings, wrapping, zoom, bookmarks, file actions, selection and Go to Line.

Validation: 88 native document assertions passed; running application verified encoding menu, UTF-8 BOM conversion updating dirty/status state, and Wrap action updating the editor/status. Subtle appearance visually verified. Independent review found a possible stale line count after the Go to Line modal; repaired with a live attachment/line-count check and explicit match-array bounds guard. Full menu matrix and light appearance have not been independently exercised.
