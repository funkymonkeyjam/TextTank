# Native build and evidence

Only arm64 is currently built and checked. The minimum system version and canonical architecture come from `Dependencies.lock.json`, validated by `scripts/build_config.py` for the shell, generator and engine builder; it does not certify an older macOS runtime. No Developer ID identity, entitlement or notarization flow is configured. Review bundles remain ad-hoc signed, incomplete previews.

Run `scripts/build.sh`, `scripts/test.sh` and `scripts/test-performance.sh` in that order. Debug is the default. To test Release, supply `CONFIGURATION=Release` to each command, including `scripts/package-review.sh` if packaging that configuration. The generator and Info.plist use matching configuration paths and deployment settings. Regenerate with `python3 scripts/generate-project.py` after adding or moving sources; CI rejects project drift.

Scintilla derived data and outputs are private to each checkout and configuration. Lexilla is copied from the already verified source manifest into `build/vendor/<configuration>/lexilla-work/`, where make writes its objects and archive. The shared Vendor source checkout is never a build-output destination. Copied source bytes are refreshed; unexpected files are rejected; all private Lexilla objects are rebuilt on every build invocation, so changes to flags, compiler or transitive headers cannot reuse stale objects.

Each native suite remains a real script with explicit test sources, defines and layering boundaries. Native bridge, search and user-lexer implementations come from the validated signed application frameworks; checks do not recompile them. Swift product sources still use the legacy per-script lists during migration. Do not compile two suite/probe scripts concurrently in one checkout: their final check-binary and log paths remain shared.

The document-check executable drives many owned document-window transitions without running the normal application event loop. A long CLI prefix on this Mac accumulated AppKit animation workers and blocked native save-panel creation; the same prefix from the accepted pre-catalog source reproduced it. The `TESTING` build therefore disables only its owned document-window transition animations. Production builds retain system animations, and the actual native save panels, review sheets, close routes, Cancel actions and deadlines remain unchanged. Functional check results do not certify physical transition animations. Diagnostic controls and source identities are execution evidence, not source-archive package certification.

`scripts/test-documents.sh` compiles one native check executable, then always runs two
required processes: the existing document checks and configuration input accessibility
checks (`--configuration-input-accessibility`). Each retains its own watchdog, status
and normal completion marker; a failure in either fails acceptance. Both processes create
their owned support directory and document controller before `NSApplication`, check
singleton identity, and use the same accessory activation policy. The complete test
runner therefore records 32 suites, including all prior 31 and the new input checks.
A combined CLI prefix failed native review/save-panel creation with saturated AppKit
animation workers; paired controls passed the full original document checks and all
input checks in separate processes on identical product bytes. This isolates test
process state without omitting assertions, changing deadlines or changing production
animation, sheet or document behavior. It does not establish a universal framework cause.

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
the app alongside NativeSearch and Scintilla. Swift check-source migration is still pending.

Native check clients now link the actual signed application EditorBridge, NativeSearch and
Scintilla artifacts. `runtime_artifacts.py` records separate Debug/Release manifests after
strict signing and rejects changed source/configuration/header bytes, additional untracked
build inputs, pinned dependency changes, compiler/SDK differences, altered module metadata
and changed app files before reuse. Each linked native image is resolved and hashed inside
the check process, and required image-proof markers accompany normal suite completion.
For an exact-source archive build, pass its `build/artifacts/Debug/manifest.json` through
`TEXTTANK_ARTIFACT_MANIFEST`; current checkout inputs must still match. This establishes local
input/artifact identity, not archive binding, source stability or package provenance. Swift
product sources are still compiled by the legacy test configurations during this stage.

Dependency inspection failures are fatal for native check executables; a missing inspector
cannot turn required image proofs into an empty list. The user-lexer provenance suite keeps
its eight contracts: the former second-compilation assertion now checks delegation to the
actual signed EditorBridge producer, with canonical per-file C++ flags and hashed compiler
log, response files and object evidence. Existing source/patch/upstream contracts remain.
