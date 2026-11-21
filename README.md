# TextTank

[![Native Mac checks on main](https://github.com/funkymonkeyjam/TextTank/actions/workflows/native.yml/badge.svg?branch=main)](https://github.com/funkymonkeyjam/TextTank/actions/workflows/native.yml?query=branch%3Amain)

Plain text. Sharp tools.

An independent native macOS plain-text and code editor using Swift/AppKit, Scintilla Cocoa and Lexilla. **Incomplete preview:** standard Notepad++ capability coverage remains required and is not certified. User-named automations, recorded macros, explicit Run commands and local text tools are implemented with focused checks; they are not a full-parity claim. Core editing and deterministic automations require no account or paid service.

## Requirements

- An arm64 Mac with full Xcode and its command-line tools selected, Git, make and Python 3.9 or newer. Local development and the required `native` CI check use Xcode 27.2. CI also runs an advisory compatibility check with Xcode 16.4. Each run reports the acceptance outcome for each toolchain.
- The deployment target is macOS 14; actual macOS 14/15 and Intel runtime behavior is not certified. Only arm64 is supported by these build scripts.
- Initial acquisition of pinned Scintilla/Lexilla archives needs network access. An existing verified `Vendor/` tree builds without downloads. No model, service or executable is contacted by ordinary editing or import.

## Build and test

From a source checkout (or extracted project source archive):

```sh
./scripts/build.sh
./scripts/test.sh
./scripts/swift-format.sh lint
```

Build first: standalone suites need the native framework and library outputs. `scripts/test.sh` runs every suite, requires native completion markers and records exact-source/log evidence; a source archive can run checks but cannot claim a Git tree it does not own. `scripts/test-performance.sh` adds the full synthetic performance tier. The static capability inventory is not an acceptance suite.

Debug is the default. Set `CONFIGURATION=Release` separately for each build/test/package command. Architecture and minimum OS come from `Dependencies.lock.json`; `scripts/env.sh` supplies shared build paths. [BUILDING](docs/BUILDING.md) explains configuration isolation, evidence and packaging. Review bundles are ad-hoc signed, not notarized public releases; signing is checked at build/package time, not assumed durable after other tools touch the bundle.

## Regenerate the project

`TextTank.xcodeproj` is generated: edit `scripts/generate-project.py`, then run `python3 scripts/generate-project.py` after adding or moving compiled sources. Update the relevant explicit suite source lists too. CI rejects generated-project drift.

## Layout and scope

- `Sources/`: native app, Foundation-only cores and the narrow Objective-C++ editing bridge.
- `Resources/`: allow-listed runtime data, icon and licence material.
- `Tests/`: isolated native/pure checks and synthetic fixtures; `scripts/` builds, validates and packages them.
- `docs/`: [review walkthrough](docs/REVIEW-ME.md), [product contract](docs/product-spec.md), [architecture](docs/architecture.md), [design standards](docs/DESIGN-STANDARDS.md), [capability requirements and dated mappings](docs/parity/README.md).
- Ignored `build/`, `harness/logs/` and `output/`: local artifacts and candidate-specific evidence. Historical session state and the inventory/profile research generators are outside the product tree.

[Automation rules](docs/AUTOMATION-RULES.md) and [Run/text-extension contracts](docs/EXTENSIONS-AND-RUN.md) explain explicit invocation and limits. See [research provenance](docs/research/README.md) and [third-party notices](THIRD_PARTY_NOTICES.md). No menu or assertion count is a capability-completion percentage.
