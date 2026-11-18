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

TextDocument remains responsible for file identity, byte-faithful encoding, save payload capture, disk conflict checks, recovery and monitoring. Its windowForSheet is a pure host lookup. Explicit native Save, close-review, Print and Revert entry points reveal their captured document before invoking AppKit. NSDocument's native canClose review completes before document.close removes its final tab. Native Save/Save As selectors reach the active document through the host's active adapter, which explicitly forwards document selectors and keeps NSDocument validation. Direct captured-document saves use that document's sheet adapter. A sheet prevents selecting another tab until review completes. Quit retains the existing review-all-before-close policy: Cancel closes no documents. The red close button invokes an injected terminate effect; Command-W, File Close and tab close capture only one document.

The host explicitly mounts/unmounts retained presentation roots and updates title, represented URL, edited marker, responder routing and toolbar validation. Getters do not change focus. The toolbar is created once per host, retains customization and one UUID-dispatched Automations drop-down. Per-tab Find, Clone, caret, scroll and last-focused pane remain in the same editor objects. No document state is reapplied on switches. One workspace frame uses the existing isolated frame policy. There is no New/Open/Close movement or animation; native full-screen transitions remain system behavior.

## Lifetime and routing

Open document, live editor, active tab and visible presentation are separate facts. The runtime registry resolves an editor to a still-open DocumentID and presentation, including detached inactive tabs. Closing unregisters it before late callbacks can apply, even when the editor is retained. Auxiliary panels do not change current document. Search, Run, Function List, automations, utilities, macros, settings, session capture and monitoring use explicit facts; revision, selection and captured identity guards remain required. Standalone owned editor checks may use their actual native window only when no document registry owns that editor; a retired document editor never falls back to that route.

Only the mounted active tab in a visible, non-minimized host runs recurring status work. Recovery and disk monitoring remain document services. Existing event/tick ordering, bounded immutable metrics capture, one worker and stale-revision rejection remain intact. Document metadata events reconcile tabs by TabID; status polling does not rebuild or drive tabs. Metadata changes reuse native controls and preserve focus. Tabs expose selected radio/tab semantics; the strip is Documents. Close targets are at least 28 points with a gap. Tabs shrink before horizontal overflow.

## Empty state and persistence boundary

Closing the final tab keeps the host open and TextTank running, without creating an untitled document. The empty host offers New/Open in the toolbar and menu; document commands are disabled. Its red close button still invokes Quit. Stage 1 adds the context commands, bulk close and reopen history described below. Stage 2 adds pin/reorder/multiselection UI below; additional visible groups and a layout picker remain excluded.

WorkspaceLayoutState requires version 1, layout, focused slot and ordered group states. Each group has its slot, active-tab index and ordered tab records containing DocumentID, pinned flag, UTF-8 anchor/caret and first visible line. Validation rejects unknown or missing version, wrong counts/order/slots, duplicate documents per group, broken pin prefix, invalid active/focused references and negative offsets. No text or bytes are stored. All four layout shapes round-trip in codec tests. Nothing writes this value to disk, and existing session/recovery schema and golden fixture bytes stay unchanged.

## Evidence boundary

Acceptance must import actual canonical signed Core/Runtime modules, retain all existing suites and add isolated tab/layering checks. Native controls and owned full-screen transitions are checked separately from physical keyboard, VoiceOver and physical full-screen observation. The latter remain unverified unless observed. Exact candidate manifests, failures and requirement results are retained outside the product checkout. This note specifies behavior; it is not an acceptance claim.

## Stage 1 commands, close review and session-only reopen

DS-12, DS-20 through DS-26, DS-40 through DS-43, DS-52/53, DS-62/70/72/73,
DS-91/92/97/100 apply. Context commands capture TabID without selecting a tab;
Window-menu equivalents use the active tab. Every route, including File Close
and tab close controls, reaches the same command owner and revalidates identity.
New Tab to Right respects the pinned prefix; ordinary New still appends. Pin UI,
reordering and multi-selection are added in Stage 2 below; group UI and saved layouts remain later stages.

Core close plans contain one immutable model snapshot, ordered eligible tabs,
deduplicated final-view documents and their modified subset. Pinned tabs are
excluded from bulk plans; Close Saved keeps untitled, modified and missing files.
Runtime captures document identity/revision/format/file state. It collects all
Save/Discard/Cancel decisions before any save, stops without saves/removals on
Cancel, then performs requested saves. No views are removed unless every save
succeeds and the model/document captures still validate. Completed saves are not
rolled back. Abort restores the original active presentation and responder.
Successful removal updates the shared host once and preserves the nearest
surviving tab and the existing background single-close rules.

Closed-tab history holds at most 20 value records in memory, with file URL,
original group/index/pin and UTF-8 view offsets, plus a disk fingerprint. It holds
no editor, document or text and is never connected to session/recovery storage.
Actual close captures view state before retirement; untitled discard/clean close
records nothing. Descriptor-anchored, cancellable disk work stays off the editor
thread, with bounded history jobs and record/model revalidation. Reopen consumes
only the expected record, reads current disk bytes through the existing captured
file factory, never revives discarded text, preserves an already open document,
and restores clamped position/UTF-8 view state. Missing paths are consumed and
reported; changed disk contents are reported quietly and announced.

The conditional Locate in Workspace item is deferred: the browser has no
select-by-URL contract and needs bounded ancestor loading/selection behavior.
Reveal in Finder and Copy File Path remain explicit captured-file actions.
Native menus retain real disabled items with reasons and standard accessibility
Show Menu; new tab commands have no new key equivalents. Physical keyboard and
VoiceOver observation remain separate from owned automated native checks.

## Stage 2 organisation and transient selection

Pinning and reorder are delivered before multiple selection. Pin/unpin and in-group
reorder mutate only tab values, keep the pinned prefix, and preserve active/focused
identities and the editor responder. Batch pin/unpin retains visible relative order.
New tabs remain unpinned; close and reopen retain the Stage 1 transaction and history.

Selection is a transient Foundation value per group, separate from the version-1
layout codec. Live active membership is mandatory. Plain navigation collapses it;
modifier clicks toggle or form the range from active. Temporary document review and
registration do not silently erase it; a cancelled bulk operation restores its capture.
Context menus capture clicked identity and selected identities once. Missing members
are dropped, a missing clicked identity is a no-op, and newly selected tabs never join.
Close/Pin use the captured set only when the clicked tab belongs to it. Close Other
keeps the captured selection plus clicked tab, so an outside click cannot close chosen
work. Directional, location, New Right and Move commands retain clicked-only scope.
File Close, Command-W and each tab's X remain single-tab actions (DS-D2).

Pointer reorder uses a local mouse gesture with a drop indicator, no system dragging
session or pasteboard. Nothing changes until a valid in-strip drop; Escape, outside
drop, stale membership/order or disappearance cancels. Keyboard Move uses the same
core path. Native checks use synthetic strip positions; physical dragging is unverified.
Stable controls are retained while visual and accessibility child order agree.

Owner clarification, 18 November 2026: "Show the active tab; announce the moved tab’s
position." When active and moved tabs cannot both fit, active visibility takes priority
without changing editor focus. Both are revealed when space permits, and every move
announces the tab's position. This resolves the Stage 2 brief's competing visibility
sentences. Pin is a visible symbol; selected-inactive tabs have an outline distinct
from the active tab's weight/underline. Semantic colors, labels, disabled reasons and
announcements meet DS-14/20-23/40-43/60-63/65/70-74/80-85. Native accessibility Actions offer Add/Remove from Selection and Select Range from Active Tab through the same guarded Core gestures, without default shortcuts. Ordinary Press remains plain selection; stale Add/Remove intents and retired targets are refused. No new shortcuts,
toolbar controls, budgets, saved schema, group UI or Stage 3 commands are introduced.
