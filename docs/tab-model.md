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

Only the mounted active tab in a visible, non-minimized host runs recurring status work. Recovery and disk monitoring remain document services. Existing event/tick ordering, bounded immutable metrics capture, one worker and stale-revision rejection remain intact. Document metadata events reconcile tabs by TabID; status polling does not rebuild or drive tabs. Metadata changes reuse native controls and preserve focus. Tabs expose selected radio/tab semantics; the strip is Documents. Close targets are at least 28 points with a gap. Tabs shrink before horizontal overflow. A tab whose document has a preview can carry a third control, the eye that switches it between Source and its preview without selecting it, and a Source, Preview and Both section in its context menu; both are specified in [preview-model](preview-model.md#switching-the-mode).

## Empty state and persistence boundary

Closing the final tab keeps the host open and TextTank running, without creating an untitled document. The empty host offers New/Open in the toolbar and menu; document commands are disabled. Its red close button still invokes Quit. Stage 1 adds the context commands, bulk close and reopen history described below. Stage 2 adds pin/reorder/multiselection UI below; additional visible groups and a layout picker remain excluded.

WorkspaceLayoutState requires version 1, layout, focused slot and ordered group states. Each group has its slot, active-tab index and ordered tab records containing DocumentID, pinned flag, UTF-8 anchor/caret and first visible line. Validation rejects unknown or missing version, wrong counts/order/slots, duplicate documents per group, broken pin prefix, invalid active/focused references and negative offsets. No text or bytes are stored. A tab record may also carry `viewMode` (`preview` or `both`) and `previewSourceFraction` (the source's share of the width in Both, 0 to 1). Both are optional and are left out for a tab that shows Source, so records written before the fields existed read as Source and a Source tab is written exactly as before. An unknown mode or a fraction outside 0 to 1 is rejected. A tab record may carry `zoom`, the active pane's zoom level, and its split record `otherZoom` for the other pane, each −10 through 60. Both are optional and written only for a pane zoomed away from the Editor Settings default; a pane without one is restored at that default and follows it, so earlier records and unzoomed tabs are unchanged. A level outside the range is rejected. The mode is applied on restore only if the document still has a preview (see [preview-model](preview-model.md#presentation)). All four layout shapes round-trip in codec tests. Nothing writes this value to disk, and existing session/recovery schema and golden fixture bytes stay unchanged.

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

## Stage 3 groups and shared-view contract

DS-D1/D2/D3/D4/D6/D7/D8 and DS-10-15/20-26/30-31/35/40-43/50/52-53/60-63/65/67/70-74/80-85/90-92/97/100 apply.
The one native host renders Single, Two Columns, Two Rows or Grid (ascending slots,
left-to-right then top-to-bottom). Each group has its own stable strip, active tab,
selection and focusable empty placeholder. Several group-active presentations may be
visible; exactly one focused group supplies global commands. A known empty focused
group returns nil, never the last occupied group's document. New/Open stay available.
Native Focus Group menus (View > Editor Groups > Focus Group) and AX actions provide a keyboard route without unverified keys.

Runtime document registration is by DocumentID, presentation ownership by TabID.
Every tab owns a distinct primary TTEditor, optional in-tab Clone, Find/status tree
and independent view state. Scintilla document references share authoritative bytes,
Undo, dirty/read-only/language; no text is copied into another buffer. A replaceable
live primary is the document service representative. Before it retires, transfer the
single document change/recovery observer to a surviving primary without resetting
revision, savepoint or Undo. Non-final close retires primary plus Clone, callbacks,
observers, timers, forms and NSDocument adapter ownership; no document close, shared
read-only change or recovery cleanup occurs. Cold weak release is required; no hidden
first editor or warmed-up release exception. Final-tab close retains native review;
Clones are not extra tabs. Whole-document results follow same-document successors,
selection-bound results cancel, and retirement chains/stale bindings remain guarded.

Group operations validate a copy and publish model, registry and native tree together
under a main-thread reentrancy guard. Move retains exact view/pin/state; an existing
destination view wins and the source retires. Open in Another Group creates an unpinned
ordinary view without a Clone, copying only initial pane view state; a destination
view already present is focused unchanged. Selected Move captures source identities
in order (clicked outside selection is single), validates all before one commit, and
focuses the resolved clicked/prior-active target. Source selection reconciles after
final active resolution; destination selects the resolved moved set. No cross-group drag.

Layouts add empty groups without moving tabs. Reduction preserves Group 1, appends
removed groups' pins then ordinary tabs in source slot/tab order, and deduplicates
without closing a document. Single collapse designates the focused active TabID as a
global winner: every other view of that document is skipped/retired before it can win
an earlier merge. The exact winner joins at its own source group's turn with its pin,
caret/scroll/Find/Clone state. Other documents retain destination/first encountered
views. If a removed group had focus in a non-Single reduction, focus Group 1 and the
resolved old active document there; empty removed focus retains a valid destination
active or nil. Surviving focus is unchanged. Orientation-only changes preserve groups.

Owner-confirmed Grid Close Group transfers to the lowest-numbered other group and
leaves its pane empty; empty Grid/Single disable it. In two panes, the other group
survives and normalizes to slot 1. A focused closed group resolves its old active
document in the destination; a background close preserves focused group/active.
Organization dedup retires views without adding explicit-close history or prompts.

Menu captures carry a transient live group token, not only reusable GroupSlot.
Remove/recreate invalidates old menus, while orientation-only continuity retains
tokens. History intentionally stores only a slot. Explicit file-view closes record
that TabID's offsets/pin/index even when another view survives. Live-document Reopen
creates/focuses a shared view without disk I/O: new views restore recorded pin,
region-clamped index and UTF-8-clamped viewport; an existing destination stays unchanged.
Session/recovery/all-document search stay one per document; capture selection from
focused or per-document MRU live editor. Chooser rows use TabID plus group identity.

The trailing layout picker stays outside scrolling strips. Native dividers enforce
320 x 200 total group bounds with responsive Find/status, shared chrome counted once,
and screen-aware content/frame fit. Unfittable layout refuses atomically with status
and announcement. Single retains its normal minimum; no gratuitous shrink. Same layout
preserves divider ratios; layout changes reset equal shares, with aligned Grid columns.
Visible group-active status work is bounded (no per-Clone job); hidden/retired work stops,
while recovery/monitoring remain per document. Reference shortcuts remain unassigned
until conflict verification. Stage 4 extends explicit session persistence below; extra
windows, tear-off, comparison/AI engines, named collections and automatic restore remain outside this contract.


## Stage 4: document targets and explicit session layouts

`DocumentTarget` is a Foundation value: runtime DocumentID, shared editor revision,
load epoch, byte length and oriented UTF-8 selection ranges captured on the main actor
when work starts. It contains no tab, group, pane, path or focused-editor reference.
Runtime resolution retains the same open TextDocument identity through switches, moves,
layout changes, collapse and non-final view closes. Final close invalidates it; reopening
the same path cannot revive it. A successful reload advances the document load epoch,
even for identical bytes; failed reads that change nothing do not. Results require both
the captured epoch and the expected-revision bridge guard. Read-only rejection names
the document. Future comparison and AI consumers must use this contract.

An automation chooses the focused group's active view at workflow invocation. For the
modeless palette, this is Run, not opening/Cancel; after Run starts the target is frozen
before parameter prompts, progress or preview. Selection drift of a still-live origin
view remains a rejection. If that view retires while the document survives, apply to the
same document's representative using captured byte ranges, without substituting a
survivor's selection or moving it to fake a match. One result remains one grouped Undo.
Every source-bound output revalidates identity, revision and reload epoch after preview;
file output revalidates again after its Save panel. Closed or stale sources cannot create a
result document, export or update the clipboard. Selection input also checks live-origin
selection drift; whole-document external output ignores caret-only changes and may export
from a read-only source. Independent clipboard/file inputs do not bind unrelated documents.
Direct deterministic automations gain no required preview or confirmation. UUIDs route
workflows; names remain editable data. Existing standalone native editor clients retain
their explicit view/window-lifetime behavior, separate from real document targets.

`WorkspaceSession` version 1 gains Optional `layoutState`; absent remains the old wire
format and golden bytes. Session documents/text occur once per NSDocument. Layout tabs
store SessionDocument IDs (not live runtime IDs), ordered groups, focused group, active
indices, pins and per-view selection/first visible line. Restore allocates fresh runtime
and recovery identities, maps saved IDs explicitly and creates shared views of each
single restored Scintilla document/Undo history. View offsets clamp to UTF-8 boundaries.
A split tab also records its other pane's selection and first visible line, the two horizontal
scroll positions, the focused side and the vertical divider's proportion. This optional v1
metadata restores the Clone inside the same tab on automatic or explicit layout restoration.
The tab's existing range and first visible line still refer to its active pane for older readers.
Tabs without split metadata restore one pane. Split panes also retain their individual Wrap
settings. A wrapped viewport records the physical document line and wrapped subrow at the top.
An inactive tab retains these positions until its divider and pane widths are available. The
native view completes the scroll as it paints the visible rows. An original that now opens in
deferred large-file mode stays unwrapped until the user chooses otherwise. Older split fields
without Wrap metadata use the current wrapping policy and their saved display rows.
The original strict SessionDocument selection/format/text/envelope validation remains.

All documents and the layout policy are validated before any document opens. Invalid,
unknown/missing-document, unsupported or malformed optional layouts are recoverable:
valid document snapshots still restore. Empty workspaces use the valid saved layout if
it fits, otherwise Single Group in session order with one view per document and a visible
announcement. Nonempty-workspace safety takes precedence over this fallback: preserve
existing layout, tabs and focus group, append restored documents to the captured focused
group and announce that the saved layout was not applied. Determine the policy before
creating documents and revalidate it at actual Restore after any modal/inspection wait.
Confirmation describes whether the saved layout will be applied. Original files stay
untouched; every snapshot opens as a new unsaved document. Existing session original-file
inspection remains explicit, off-main and once per document.

Recovery keeps its existing format and one snapshot/document; relaunch recovery yields
one document/view and never restores a layout. A later explicit session restore creates
new independent unsaved documents, intentionally not content-deduplicated with recovery.
Closed-tab history stays transient and is never serialized. No automatic last-session
reopen, second workspace window, collections, comparison engine or AI provider is added.
DS-14/20-23/35/40-43/62/70-73/84/90-92/100-101 govern these additions.

## Docked Workspace Browser

Owner decision DS-D11 (23 November 2026); DS-10/11/13/15/20-23/60/62/63/67/70-74 apply. The Workspace
Browser is a sidebar inside the one workspace window. There is no browser panel: View > Workspace
Browser, the Command Palette, Add Folder to Workspace and Monitor Current File all reach the same
docked view. The browser's store, lists, open route and encoding offer are unchanged; only the view moved.

The window's content is one root split, `WorkspaceSidebarSplit`. Its last pane is the editor area (the
layout picker and the editor group container), which is never removed or rebuilt. The sidebar is
inserted before it when shown and removed when hidden, so 1, 2 or 4 groups, their dividers, Clone
panes and each tab's Source, Preview or Both share whatever width remains, exactly as they shared the
whole window before. The sidebar draws on the window's background: no `NSVisualEffectView`, no
source-list material, no change to the custom-materials budget.

Widths come from `WorkspaceSidebarGeometry` in the Foundation-only core. The sidebar is at least 260
points, at most 480 and 280 by default; its divider is 1 point and can be dragged between those
bounds, never past the point where the editor area would lose the minimum of its layout
(`TabGroupGeometry.minimumContent`). Only a drag changes the remembered width. The collapse rule at
small sizes is explicit (DS-67):

1. While the sidebar is shown the window's content minimum is the editor layout's minimum plus the
   divider plus 260 points (1061 by 500 for one group or two columns). It is never lower than the
   minimum without the sidebar, and hiding the sidebar restores that minimum.
2. Showing the sidebar in a narrower window grows the window to the new minimum and keeps it on
   screen. A full-screen window is never resized. If the screen cannot fit the minimum, the command
   is refused with a status message and nothing changes.
3. A narrowing window takes width from the sidebar first, down to 260 points. The editor groups keep
   at least 320 points each.
4. Inside a group, Both keeps its own rule: source and preview keep 120 points each while there is
   room and otherwise share the width equally.

Nothing collapses to zero and no pane overlaps another; the sidebar's own controls fit at 260 points.

View > Workspace Browser keeps its command identity and has no shortcut. It is a toggle with a
checkmark (DS-22). Choosing it while hidden shows the sidebar and moves the keyboard to its list;
choosing it while shown hides the sidebar. Escape in the sidebar returns the keyboard to the text and
leaves the sidebar showing. Hiding returns the keyboard, if the sidebar held it, to the view that had
it before, or to the active tab's editor when that view is gone. Showing for another reason (a
restored layout, Add Folder, Monitor Current File) never moves the keyboard. None of these changes a
document, its selection, scroll position, Undo history or the active tab. In the list the arrow keys
move, typing selects by name, and Return opens the selected file or selects its tab, expands a folder,
or shows an open document. The sidebar is an accessibility group named "Workspace Browser" holding an
outline labelled "Workspace files"; its controls join the window's key-view order after the layout
picker. The three views are chosen from a pop-up, because three segment titles do not fit 260 points.

`WorkspaceLayoutState` version 1 gains two optional keys, `sidebarShown` and `sidebarWidth` (points,
greater than 0 and at most 10,000; clamped to the bounds when applied). A workspace whose sidebar was
never shown writes neither, so its files and the golden fixtures are byte-for-byte unchanged. Once it
has been used both are written, `sidebarShown` as true or false. A layout without the keys changes
nothing when it is applied, which at launch means hidden: an older file opens as it always did. The
automatic launch file carries the layout, so the sidebar's state returns at the next launch. It is
applied at launch even when last session's documents are not reopened, because it describes the
window, as its frame does. Restoring an explicit session applies the keys its layout has.

Physical keyboard, VoiceOver, pointer dragging of the divider and full screen with the sidebar shown
have not been observed; the native checks drive the same views and commands in an owned window.

## What a tab shows, the mouse and the list of open tabs

A tab's title is the document's name and nothing else. State is drawn beside it, as shapes with
words behind them, never as a character in the title and never by colour alone (DS-62):

- **Edited.** The close button shows a filled dot instead of its cross. Under the pointer, or while
  the close button has the keyboard, it shows the cross. It is the same 28 by 28 button with the
  same action, so a click on the dot closes through the same Save / Don't Save / Cancel review as a
  click on the cross (DS-12), and an edited tab never looks as if it cannot be closed.
- **Changed outside TextTank.** A warning triangle between the title and the close button. Its
  tooltip and accessibility text give the document, the notice and what to do next (DS-70, DS-85).
- **Selected for comparison.** A pair of opposed arrows in the same place, with its own tooltip.
- **Pinned** remains the pin in place of the document icon; Source, Preview and Both remain the eye.

A click on a state symbol is a click on its tab; a Control-click or secondary click opens the tab's
menu. The symbols are 16 points wide with four points on either side, so the title, each symbol, the
eye and the close button never abut (DS-14, DS-74).

The tab's own accessibility label is one whole string for each combination of what the tab shows,
pinned and edited ("notes.md, pinned, edited, showing Preview"), and one whole sentence form around it
for an outside change, for comparison and for the two together ("notes.md, edited. Changed on disk.
Selected for comparison."), so each can be translated as a whole (DS-84).

**What gives way when a tab is narrow.** Tabs shrink from 220 to 130 points before the strip scrolls.
From the trailing edge, in order of who keeps their place:

1. the close button, which is also the edited dot: always;
2. the eye of a tab in Preview or Both: always, because it is state;
3. the outside-change symbol: always, because it warns that a save may overwrite other work;
4. the comparison symbol: only while the title keeps 50 points, the width a title has beside the eye
   at the minimum;
5. the eye a Source tab shows under the pointer: only while the title keeps 82 points.

So a 130-point tab shows close, and at most one of the two symbols, the outside change first; a
130-point tab in Preview or Both shows close, the eye and the outside change, and its title keeps 30
points. Whatever is not drawn is still in the tab's tooltip, its accessibility label and the list of
open tabs.

**Tooltip.** A tab's tooltip is the file's full path with the home folder written as `~`; a document
with no file shows its name. When the file changed outside TextTank the notice follows on a second
line. Only the home folder itself is abbreviated, not a sibling whose name starts the same.

**Mouse.** A click with the other (middle) mouse button closes the tab it is pressed and released
on, anywhere on the tab, without selecting it first. It goes through the close button's route
(`WorkspaceWindowController.closeTab`), so unsaved changes get the same review and Cancel leaves
everything as it was (DS-12). Pressed on one tab and released on another, or on the empty strip, it
does nothing. A double-click on the empty part of the strip focuses that group and runs the same
action as File > New. A double-click on a tab is two clicks on that tab and nothing more. A tab's
controls take their own clicks, so the end of a reorder never counts as a click on the strip. The
window's frame has first refusal over its inside edge (`FrameTextClick`): a point the frame claims is
never treated as empty strip, so AppKit's own handling of a double-click there is untouched.
