# Workspace and tab ownership - Stage 0

Stage 0 replaces the temporary hidden-window tabs with one native workspace window and one rendered editor group. DS-D1, DS-D2, DS-D3, DS-D6, DS-D7 and DS-10 through DS-15 govern the host. Native window tabbing stays disabled. The tab core is Foundation-only in TextTankCore; AppKit ownership stays in TextTankRuntime.

## Identities and invariants

DocumentID identifies one runtime TextDocument, independently of its path or recovery identity. Reopening a path creates a new identity. TabID identifies a view in a group. GroupSlot is 1 through 4. A Clone is a second pane inside the same tab, never a tab or group.

- I1: Scintilla retains the only authoritative text and Undo history per document.
- I2: A group contains at most one tab for each document.
- I3: Future views in different groups share text, dirty/read-only state and Undo, with independent view state. Stage 0 renders only Single.
- I4: Pinned tabs form a contiguous prefix. There is no pin UI in Stage 0.
- I5: A nonempty group has one active member; an empty group has none.
- I6: Layout determines group count; slots are ordered and unique; focused group exists.
- I7: TabIDs are unique across the workspace. Every registered open workspace document has a tab.
- I8: Final-view removal requires successful document close review. Non-final-view removal does not close the document. Clone keeps its separate retirement path.

Core operations validate a proposed copy before committing it. Rejection leaves the original value unchanged. Opening an existing document in the focused group activates it; a new tab appends. Cycling wraps in visible model order. Closing an active tab selects its right neighbor, otherwise its left. Runtime background close captures the old active identity, activates the reviewed tab and returns only after successful close. Cancel leaves the reviewed tab showing. Explicit selection or subsequent document interaction clears the temporary return target.

## Native ownership and presentation

WorkspaceWindowController alone owns the NSWindow, shared toolbar, stable tab strip and mounted presentation. It never becomes an NSDocument's registered window controller and its document is never switched. Each TextDocument retains its own EditorWindowController adapter, registered only to that document. The adapter's native window is nil: it owns the retained editor/Clone/Find/status view tree, not an NSWindow. Its explicit hostWindow accessor is for presentation, never lifetime. Its showWindow selects its tab; its close detaches only that presentation. NSDocument closes no shared window.

TextDocument remains responsible for file identity, byte-faithful encoding, save payload capture, disk conflict checks, recovery and monitoring. Its windowForSheet explicitly selects that captured document and supplies the host. NSDocument's native canClose review completes before document.close removes its final tab. Native Save/Save As selectors reach the active document through the host's active adapter, which explicitly forwards document selectors and keeps NSDocument validation. Direct captured-document saves use that document's sheet adapter. A sheet prevents selecting another tab until review completes. Quit retains the existing review-all-before-close policy: Cancel closes no documents. The red close button invokes an injected terminate effect; Command-W, File Close and tab close capture only one document.

The host explicitly mounts/unmounts retained presentation roots and updates title, represented URL, edited marker, responder routing and toolbar validation. Getters do not change focus. The toolbar is created once per host, retains customization and one UUID-dispatched Automations drop-down. Per-tab Find, Clone, caret, scroll and last-focused pane remain in the same editor objects. No document state is reapplied on switches. One workspace frame uses the existing isolated frame policy. There is no New/Open/Close movement or animation; native full-screen transitions remain system behavior.

## Lifetime and routing

Open document, live editor, active tab and visible presentation are separate facts. The runtime registry resolves an editor to a still-open DocumentID and presentation, including detached inactive tabs. Closing unregisters it before late callbacks can apply, even when the editor is retained. Auxiliary panels do not change current document. Search, Run, Function List, automations, utilities, macros, settings, session capture and monitoring use explicit facts; revision, selection and captured identity guards remain required. Standalone owned editor checks may use their actual native window only when no document registry owns that editor; a retired document editor never falls back to that route.

Only the mounted active tab in a visible, non-minimized host runs recurring status work. Recovery and disk monitoring remain document services. Existing event/tick ordering, bounded immutable metrics capture, one worker and stale-revision rejection remain intact. Document metadata events reconcile tabs by TabID; status polling does not rebuild or drive tabs. Metadata changes reuse native controls and preserve focus. Tabs expose selected radio/tab semantics; the strip is Documents. Close targets are at least 28 points with a gap. Tabs shrink before horizontal overflow.

## Empty state and persistence boundary

Closing the final tab keeps the host open and TextTank running, without creating an untitled document. The empty host offers New/Open in the toolbar and menu; document commands are disabled. Its red close button still invokes Quit. No later-stage context commands, bulk close, reopen history, pin/reorder/multiselection UI, additional visible groups or layout picker are added.

WorkspaceLayoutState requires version 1, layout, focused slot and ordered group states. Each group has its slot, active-tab index and ordered tab records containing DocumentID, pinned flag, UTF-8 anchor/caret and first visible line. Validation rejects unknown or missing version, wrong counts/order/slots, duplicate documents per group, broken pin prefix, invalid active/focused references and negative offsets. No text or bytes are stored. All four layout shapes round-trip in codec tests. Nothing writes this value to disk, and existing session/recovery schema and golden fixture bytes stay unchanged.

## Evidence boundary

Acceptance must import actual canonical signed Core/Runtime modules, retain all existing suites and add isolated tab/layering checks. Native controls and owned full-screen transitions are checked separately from physical keyboard, VoiceOver and physical full-screen observation. The latter remain unverified unless observed. Exact candidate manifests, failures and requirement results are retained outside the product checkout. This note specifies behavior; it is not an acceptance claim.
