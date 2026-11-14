# Recipe toolbar and parser review — 2026-11-14

Working-tree review based on `1d41ee10fb39ce10054d5789e88a4f297fcf28de`; final source identities are below. No Git changes made by the reviewer.

## Independence and scope

Independent review of reference agent's AutomationCore strict parsing/regex and root's App.swift toolbar observer/close integration. The reviewer authored AutomationController, so its fresh inspection and native regressions are self-review, not an independent certification. Actual controller execution uses Scintilla in an AppKit window with an installed NSToolbar button. No live EventKit permission, list read or export was performed.

## Finding repaired

**P2 — configurable regex could hang direct cleanup on the main thread.** Before repair, `removeMatchingLines` used `firstMatch` without interruption. Pattern `(a+)+$` on 32 `a` characters followed by `!` exceeded a two-second subprocess deadline; the reviewer killed only that isolated probe. Since Controller applies transforms synchronously, this stalled app interaction even for a 33-character document.

Reference repaired this with `enumerateMatches(.reportProgress)` and a cumulative 100ms matching budget, raising an actionable error before editor mutation. Independent native controller regression now confirms this exact pattern rejects in under two seconds with document bytes, revision and dirty state unchanged. This is a bounded custom line-regex fix, not a claim that every transform or arbitrarily large document has a cancellation/performance guarantee.

## Native observed results

`scripts/test-automation-ui.sh`: **30 assertions passed** on the final hashed sources. Log: `harness/logs/automation-controller-checks.log`.

- The named automation button is installed in an actual NSToolbar belonging to the same native window (`button.window === window`). Its action resolves the current saved definition by UUID.
- The observed browser plain-input fixture contains **28** checkbox-marked ingredient rows, independently counted. All eight remaining source lines are structural headings or the explicitly configured Garnish (optional) label.
- Clicking the installed button produces exactly the independently retained expected text and all 28 rows, preserving quantities, alternatives, duplicates and copied punctuation/spacing. The editor/window remains the same and the new-document callback is never invoked.
- One Scintilla Undo restores the complete original browser-copied text exactly.
- Adding an unknown unmarked continuation causes the shared direct invocation to reject before changing bytes, revision or dirty state. The error path was called directly to avoid automating modal dismissal; the successful complete recipe uses the actual button action.
- Renaming/reloading preserves toolbar identity, menu/shortcut name and behavior; existing custom configuration is not replaced by presets. Missing preview flag applies directly. Configured selection cleanup preserves surrounding text and undoes together.
- Durable identical-export matching includes exact row order, duplicate rows and destination identity. This test does not create any reminders or prove a live EventKit send.

## App integration inspection

Root's controller installs named workflow identifiers through the toolbar factory, observes `.textTankAutomationsDidChange` for label/pin refresh, and routes Close Tab through native `performClose` (retaining NSDocument dirty-close handling). Teardown removes observers and focus callbacks; the primary editor is retained separately rather than force-casting a disappearing NSDocument from an update callback. No additional confirmed blocking defect found in these inspected paths.

## Limits

The shell test environment has no physical NSScreen. Native AppKit attachment/action and Scintilla results are observed; physical display, actual browser copy/paste and full root controller toolbar behavior require root's separate CUA evidence. Full arbitrary Markdown parsing is not claimed: malformed/unknown structures remain data or reject explicitly. Regex semantics here are configured automation rules, not a claim of Notepad++ Boost search parity. Live Reminders export remains pending explicit consent/destination.

Advanced configuration help still lists the older processing-step subset; documenting newly available steps is a nonblocking copy improvement.

| File | SHA256 |
|---|---|
| `Sources/Automations/AutomationCore.swift` | `9de8a141b5ba7bae916e439ce1d7ef2cf1d70a4b9bede9edb37b8371bec20169` |
| `Sources/Automations/AutomationController.swift` | `f6964277d8317e1dcc69ffffff6425a0afe06c90875b083c1f255eb71d1067a0` |
| `Sources/TextTankApp/App.swift` | `995b41706bc8ff889cefc3f5ecd938854b5bcaf9358cd4be31fdc33bf45d7997` |
| `Tests/AutomationControllerChecks.swift` | `450915245b36954a22cb01df372ec7c38569c1c3a655492c856ae031165a6b8c` |
| `Tests/Fixtures/recipe-browser-plain-input.txt` | `5896b76224cea2520be6fd089a3b6e6f2e293a3037f139f80cf0f69663853864` |
| `Tests/Fixtures/recipe-browser-cleaned-expected.txt` | `ec2e8425ddf4479b10563c1cb19b877fd4059182f310da2c298ca0022d8ed3fa` |
