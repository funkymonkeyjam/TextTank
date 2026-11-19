# Native build and evidence

Only arm64 is currently built and checked. The minimum system version and canonical architecture come from `Dependencies.lock.json`, validated by `scripts/build_config.py` for the shell, generator and engine builder; it does not certify an older macOS runtime. No Developer ID identity, entitlement or notarization flow is configured. Review bundles remain ad-hoc signed, incomplete previews.

Run `scripts/build.sh`, `scripts/test.sh` and `scripts/test-performance.sh` in that order. Debug is the default. Use `CONFIGURATION=Release` for the production build and matching packaging. Native check clients use Debug module metadata with testability; Release keeps optimization and `ENABLE_TESTABILITY=NO`. The generator and Info.plist use matching configuration paths and deployment settings. Regenerate with `python3 scripts/generate-project.py` after adding or moving sources; CI rejects project drift.

Scintilla derived data and outputs are private to each checkout and configuration. Lexilla is copied from the already verified source manifest into `build/vendor/<configuration>/lexilla-work/`, where make writes its objects and archive. The shared Vendor source checkout is never a build-output destination. Copied source bytes are refreshed; unexpected files are rejected; all private Lexilla objects are rebuilt on every build invocation, so changes to flags, compiler or transitive headers cannot reuse stale objects.

Each native suite remains a real script with explicit test sources, defines and layering boundaries. Native bridge, search and user-lexer implementations come from the validated signed application frameworks; checks do not recompile them. Swift checks compile Tests sources only and import the actual built Core/Runtime modules; pure Core suites do not import Runtime or AppKit. Do not compile two suite/probe scripts concurrently in one checkout: their final check-binary and log paths remain shared.

The document-check executable drives many owned document-window transitions without running the normal application event loop. A long CLI prefix on this Mac accumulated AppKit animation workers and blocked native save-panel creation; the same prefix from the accepted pre-catalog source reproduced it. The document test supplies an explicit owned dependency that disables only its document-window transition animations; product compilation has no `TESTING` flag. Document windows now disable open/close transition animation in production as well, per the owner's DS-D7 follow-up; native save panels, review sheets, close routes, Cancel actions and deadlines remain unchanged. Functional check results do not certify physical transition animations. Diagnostic controls and source identities are execution evidence, not source-archive package certification.

`scripts/test-documents.sh` compiles one native check executable, then always runs seven
required processes: the existing document checks and configuration input accessibility
checks (`--configuration-input-accessibility`), plus Stage 0 workspace checks (`--tab-workspace`) and Stage 1 tab-command checks (`--tab-commands`), plus Stage 2 organisation checks (`--tab-organization`) and Stage 3 group checks (`--tab-groups`) and Stage 4 integration checks (`--tab-integrations`). All five tab processes copy the byte-identical compiled check client into an owned app bundle with the selected product document-type metadata, a private bundle identity and no Finder-handler rank. It uses an owned NSApplication event loop for native save/close/full-screen behavior and explicitly foregrounds that owned client before the unchanged key-window/full-screen assertions. Cooperative `NSApp.activate()` can decline foreground activation even on an available desktop; the fixture uses AppKit's explicit foreground call, while production activation stays unchanged. The two prior processes retain their original CLI lifecycle. Each retains its own watchdog, status
and normal completion marker; a failure in any process fails acceptance. All seven processes create
their owned support directory and document controller before `NSApplication`, check
singleton identity. The two CLI processes use accessory activation; the five owned tab app processes use regular activation to exercise native window/review behavior. The complete test
runner records 57 suites: all 54 accepted Wave 4/Foundation suites plus D1 Core layering, projection behavior and native controller checks. `scripts/test-review.sh` uses actual signed canonical Core/Runtime modules; diff work runs detached from MainActor, while native capture/application use owned isolated documents.
A combined CLI prefix failed native review/save-panel creation with saturated AppKit
animation workers; paired controls passed the full original document checks and all
input checks in separate processes on identical product bytes. This isolates test
process state without omitting assertions, changing deadlines or changing sheet or document behavior. The later DS-D7 production animation policy is independent of that process-state isolation. It does not establish a universal framework cause.

The isolated toolbar fixture exercises synchronized windows, display modes, visibility and actual overflow actions. AppKit emits `NSToolbarLabelStack` constraint-invalidation runtime warnings during this sequence. Removing the added accessibility assignment/traversal or toolbar KVO observations did not remove them, and a smaller matched AppKit-only control did not reproduce them; their cause is not established. Subsequent viewport, dispatch, UUID and Undo checks pass. These runtime messages are retained separately from compiler diagnostics and do not establish physical layout or running-app accessibility certification.

Acceptance records a clean starting git tree, runs every suite even after a failure, refuses native exit-zero runs without their normal completion summary, then compares the final tree and dirty state. The exit code and acceptance-log hash are recorded atomically. A source archive without its own git checkout root can run checks but cannot produce a stable source-tree claim; an unrelated enclosing repository does not supply that identity. Packaging requires matching clean-tree evidence and the original log hash; it labels manually supplied CI metadata as self-reported. Public logs normalize local filesystem prefixes and retain both original and public log hashes.

Dependency acquisition verifies pinned size and SHA-256 before atomic publication. Extraction rejects unsafe member paths, links and special files, verifies the entire pinned source tree and publishes it only afterward. Extra vendor source files are rejected; only historical Lexilla object/archive outputs and Finder metadata are allowed outside the manifest. The normal existing-source build requires no download.

Packaging stages on the delivery filesystem and removes its stage on failure. After a successful delivery it retains only the newest timestamped previous delivery. The launcher verifies an archive checksum before extraction, waits for the launched app to exit and cleans its temporary copy; interruption keeps the possibly running copy rather than deleting it. Agents test these scripts with isolated synthetic candidates and never invoke the actual app launcher without explicit permission.

`build-pipeline-checks` adds isolated fault scenarios for archive/extraction boundaries, extra sources, stale headers, bad configuration/arguments, mismatched or tampered evidence, public log paths, retention, resource/license inputs and the strict icon renderer. It supplements all existing native suites.

Product documentation is copied from the explicit `REVIEW_DOCUMENTS` list in `scripts/package_review.py`; session prompts, run-state and dated worker notes are not review docs. The legacy `render-audit-report.swift` is retained because external callers are unknown; it is not part of build, acceptance or packaging validation. Its presence in a project source archive is not a claim that it produces current candidate evidence.

The generated graph includes NativeSearch, a Foundation Objective-C++ framework. Canonical
builds embed and ad-hoc sign it before the application, retaining fatal signing and strict
verification failures. Its public module exports only TTSearchEngine.h.

The build also inspects actual application code images (including the Debug dylib) and
NativeSearch install names before signing. Embedded runtime dependencies must use @rpath;
an absolute /Library/Frameworks dependency fails rather than passing build-only evidence.

EditorBridge builds the editor bridge and user lexer once for the application target,
linking the existing pinned engines. Its module exports TTEditor.h; it is signed before
the app alongside NativeSearch and Scintilla. Checks compile no product source copies.

Native check clients now link the actual signed application EditorBridge, NativeSearch and
Scintilla artifacts. `runtime_artifacts.py` records separate Debug/Release manifests after
strict signing and rejects changed source/configuration/header bytes, additional untracked
build inputs, pinned dependency changes, compiler/SDK differences, altered module metadata
and changed app files before reuse. Each linked native image is resolved and hashed inside
the check process, and required image-proof markers accompany normal suite completion.
For an exact-source archive build, pass its `build/artifacts/Debug/manifest.json` through
`TEXTTANK_ARTIFACT_MANIFEST`; current checkout inputs must still match. This establishes local
input/artifact identity, not archive binding, source stability or package provenance.

Dependency inspection failures are fatal for native check executables; a missing inspector
cannot turn required image proofs into an empty list. The user-lexer provenance suite keeps
its eight contracts: the former second-compilation assertion now checks delegation to the
actual signed EditorBridge producer, with canonical per-file C++ flags and hashed compiler
log, response files and object evidence. Existing source/patch/upstream contracts remain.

Before compilation, canonical builds capture actual resolved settings for every application
project target, the pinned Scintilla target and source/toolchain inputs; recording refuses before/after differences.
User-lexer compiler evidence is immutable and scoped to that object: actual dependency-file
source/header bytes, effective options after response expansion, C++ target settings, clang/SDK
identity, response files and object bytes. A normal incremental build may retain this evidence
when the C++ producer remains valid while recording new whole-product inputs for Swift changes.
The build does not force routine recompilation to manufacture a fresh compiler log.

Core membership is declared once in scripts/core_sources.py and consumed by the generated
project. Debug checks import the build-produced Core module
metadata and link the actual signed embedded Core/NativeSearch images, with package name
TextTank. Release retains normal optimization and ENABLE_TESTABILITY=NO. Header/module
metadata remains separately hashed; code-image path/hash evidence is required for Core too.

The Runtime target builds all UI/document/service code once, and the executable is a thin
bootstrap. Native check clients import the matching build-produced Debug modules and link
actual signed embedded Runtime/Core/native code. Check compilation pins the artifact's SDK;
there are no product source arguments or product TESTING flags in the suite scripts. The five
required DocumentChecks processes install explicit owned effects before the document-controller
singleton and NSApplication; owned window animations are disabled through that dependency,
while production defaults disable document-window transition animations and retain real sheet/save behavior.

Actual Swift producers and all test compilers retain Swift 5 and warnings-as-errors with
complete concurrency checking. `compile_diagnostics.py` also rejects emitted first-party
Swift warning/error headers when a Swift 5 compiler returns zero. The guard suite runs an
actual good/bad AppKit actor-access compiler pair and checks the resolved producer settings;
intentional negative compiler output is retained separately from normal build diagnostics.
This does not certify other toolchains or macOS runtimes.

Before signing, canonical builds retain immutable per-image link records: the real Ld event,
working directory, driver and expanded response arguments, exact file-list bytes/order,
source-to-object maps, object/library hashes and actual linker dependency selections. The
LexUser compiler object and canonical Lexilla archive must each enter EditorBridge exactly
once. Generated Scintilla version code, the Debug executor archive/section inputs and the
empty preview auxiliary have explicit roles. Xcode's empty preview link may share an
overwritten dependency-info path with the real Debug application; that file is never
attributed to the preview's library selections.

The schema-3 manifest separately binds pre-sign linked identity and final signed image
hashes/UUIDs, all embedded code, and the full per-image load/reexport/weak-load/runpath
closure. Every non-system dependency must resolve inside the selected app; platform shared
cache paths remain valid without standalone disk files. Unexpected code, escaping paths,
wrong install names, forbidden Core/native UI edges, cycles and failed inspection reject.
Artifact reuse re-queries resolved settings at the selected build root and rechecks inputs,
metadata, code, retained producers and strict signing. It never queries a different source
project or searches for a substitute cached build. A valid no-op may reuse the same scoped
link/C++ producers; a changed input or missing producer cannot invent a successful link.

If an actual Swift compile changes source bytes but emits a byte-identical mapped object
without a new Ld event, the original link record stays immutable. A separate immutable
compiler refresh must retain the exact target and absolute SwiftCompile primary source,
actual driver/response/compiler/SDK/settings, source/output-map hashes and the identical
object. Driver file-list membership alone cannot prove that refresh. Missing primary
evidence or changed object bytes reject reuse.

D1 adds `scripts/test-compare.sh` using signed canonical Core/Runtime/EditorBridge images. Controller checks create owned documents/files and inject a named private pasteboard only under `TEXTTANK_TEST_PASTEBOARD=1`; they never inspect the general clipboard. Pure projection checks reconstruct both sources from side/unified/segmented mappings. Physical keyboard, wrapped reading and VoiceOver speech remain separate observations. `docs/compare-model.md` is included in the explicit packaged review documents.
