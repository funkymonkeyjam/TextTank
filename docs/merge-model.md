# Selective merge and unified patch model (D2)

Scintilla remains the sole editable document and Undo authority. Comparison renderers stay immutable,
independent and read-only. D2 adds no patch import, closed-file mutation, filter, three-way/folder merge,
provider, network, dependency or persistent format. This contract precedes implementation; acceptance
belongs to exact-candidate evidence.

## Explicit destination and change selection

Choose Original or Modified explicitly. Only a bound open editable document is eligible; a file,
clipboard, saved file or historical value is source-only. A selection uses the captured whole parent,
exact originating weak view and slice bounds. Translate its ranges into that parent, preserve bytes
outside the slice and reject retired selection origins. Whole-document capture may resolve a surviving
clone; same-path reopen never substitutes identity. Record format/BOM and shared insertion EOL at
comparison capture/Refresh, not Apply. Focus or caret changes never retarget.

Select whole blocks by comparison generation/ordinal, not decoration/table-row or inline span. Native
virtualized checkbox rows give ordinal/kind/ranges, selected value and non-colour cues. New direction,
Refresh, stale/cancel or application clears selection. Commands share titles and validation across
menu, toolbar and sheets. Busy, stale, incomplete, filtered or unpresented results cannot apply/export.
Raw block count and final coalesced edit count are distinct; final Foundation caps remain unchanged.

## Pure planning and sole application path

Validate both snapshot identities, complete raw change mapping, strict UTF8/line boundaries, monotonic
blocks and exact unchanged spans under a worker budget before payload copies. Reverse direction swaps
ranges/kinds. Selected replacements retain source order. Coalesce minimal ambiguous shared-start or
zero-width adjacency clusters only; retain untouched destination gaps, never unselected source edits.
Keep contributor ordinals for exact failing-block diagnostics, including synthetic same-anchor inserts.

One EditProposal binds the original parent DocumentTarget, revision/loadEpoch and expected bytes.
Preflight all selected ranges before mutation. Metadata/global failures name the destination; a range
failure names its block. Project parent bytes and use strict FileCodec.encode to prove representability
in the captured format before commit. Unrepresentable text rejects atomically using the existing save
error; no lossy conversion or automatic format change. No merge save or disk/clipboard read.

Final MainActor validation checks generation, both live sources, open exact destination/readOnly,
revision/epoch/bytes and format/insertion mode. Issue one single-use Foundation ReviewRequest handle and
apply with no await/modal/focus/selection gap. Existing applyEdits owns one Undo group; no second mutation
path, nested group, source renderer write or bridge API. Rejection/no-op preserves every clone's text,
oriented selections, dirty/savepoint and history. Undo/Redo through either clone restores exact bytes.

Show Destination explicitly activates the bound document for ordinary actual-history Undo/Redo. No
Undo Merge/Redo Merge bypass exists while a comparison is key; generic workspace routing stays blocked.
Ordinary Undo makes comparison stale until explicit Refresh. DS-90's focused-target wording is narrowly
interpreted as the explicitly chosen bound destination; it never means unrelated workspace focus.
The inherited DS-27 generic Undo action-name gap remains.

## Recompute and interruption

Ready -> preparing -> synchronous commit -> bounded recomputing -> ready. Clear all old coordinates
immediately at commit. Capture fresh destination and compare against the unchanged opposite captured
value, with both source bindings revalidated after awaits. No implicit file/clipboard recapture. A
successful selection merge derives its exact new slice extent, including empty; it does not use the
current caret. Explicit Refresh retains D1's current qualifying selection in the same live origin.

Tab and Saved File may rebind the saved side's parent stamp only for that exact known application,
unchanged pinned URL/savedFormat and expected dirty transition; retain captured disk bytes without I/O.
Save/Save As/reload/intervening changes receive no exception. Another comparison/clone edit invalidates
old results. One service pipeline/max two windows remain. Close cancels/drops late work.

If computation/presentation fails after commit, applied text remains applied and Undo remains available.
Keep the previous capture explicitly Out of date, old actions disabled, offer Refresh/Show Destination.
Cancel after commit cannot be described as reverting text. No stale native rollback can regain Apply.

## Unified patch

Always export the complete current raw Original -> Modified pair, regardless of destination or selected
blocks. Identical text exports zero bytes with No differences status. UTF8 model bytes carry no added
transport BOM; real leading U+FEFF, NUL, CRLF/mixed endings and absent final LF remain exact.

Patch records use LF-only line tokenization; CR is payload, including internal lone CR. D1's CR-aware
display line table cannot supply patch coordinates. Reuse the bounded first-party solver through an
explicit LF-only entry; preserve all F0/D1 default tokenization. Emit safe ---/+++ labels, standard hunk
starts/counts including zero-count BOF, three LF-record context lines and merged overlapping context.
Each affected LF-less final payload gets the standard missing-newline marker. Never normalize payload.

Captured file snapshots additionally retain a pathless descriptor-derived device/inode signature.
Protect that original inode as well as current source URLs, including a moved source with an old-inode
hardlink alias and a replaced original pathname. This additive F0 metadata has no persisted schema.

Header labels are escaped basenames/Untitled with distinct a/ and b/ prefixes, no absolute paths,
timestamps or raw control/whitespace/nonASCII injection. Bound combined escaped headers to16KiB before
allocation. Labels are metadata only. An independent test-only reader must reconstruct every corpus
pair without writer/tokenizer/diff helpers; malformed controls must fail. Owned standard-tool fixtures
record exact output/version, no fuzz/offset success; NUL consumer limitations remain separate from
required byte-exact parser checks and do not imply universal binary-patch support.

## Explicit export and staged publication

Export Unified Patch opens a native save panel explaining UTF8/editor-text/full comparison scope; Copy
Patch writes plain text only on explicit command. No clipboard read/clear during validation or polling.
Disable other result-changing actions while preparing/exporting/panel active; freeze/revalidate job.

Add a single-use prepared-output ticket beside the unchanged legacy PrivateFileStore.write. Worker
stages a0600 exclusive nofollow sibling, writes cancellable chunks, fsyncs/closes it. MainActor checks
generation/cancel/live sources and protected current source URLs/device-inode identity, then short
same-call target/directory revalidation+rename without await. No worker hop-check-return-rename race.
Refuse overwrite of compared sources including aliases/hardlinks; save-panel approval is insufficient.
Failed/cancelled/late preparation self-cleans; a ticket commits once. Rename success is committed even
if later reporting/cleanup fails. No false directory-fsync durability/global filesystem-coordination or
mid-syscall cancellation promise. Editor Undo cannot reverse patch-file/clipboard publication.

## Limits, design and gates

Retain8MiB raw/decoded/selection-parent inputs,10k final edits,8MiB expected/replacement/result parent,
Foundation final64m validation; default D2 planner/patch64m work/2s/128MiB explicit workspace/32MiB patch
output/250kLFrecords per side. Charge scans/sorts/coalescing/diagnostics/copies/encoding/header/output,
poll cancellation within1024 charged steps plus bounded opaque calls. Explicit headless correctness
profiles use512m/30s with unchanged caps; never production fallback. D1 projection retains32m/2s/128MiB
workspace/64MiB output/500krows. Resource estimates are not RSS or guaranteed latency; measure native
load/shape and final filesystem opaque work separately from explicit8ms row batches.

DS-10-15,20-27,30-31,40-45,50-53,60-63,65-67,70-74,80-85,90-92,95-97,100-101 apply. Native sheets, native
checkboxes and toolbar; no accessory managers, routine success alerts, custom colours or raised budgets.
Gate A before UI: both directions/all/singles/subsets/partial recompute sequences and independent patch
reconstruction, actual headless applier/clone Undo. Gate B: native scoped validation/state/effects/AX and
layout. Author and different verifier full canonical57-preserved-plus/default100MiB/static/Release gates,
maximum2formal product repairs, retain failures. Physical keyboard/pointer/VoiceOver/wrapped reading and
unobserved platforms/distribution require separate evidence. After accepted D2 update report preserving
all54historical pages and safely deliver exact latest verified Release. Stop after D2.
