# TextTank

Read `docs/product-spec.md`, `docs/architecture.md`, `docs/DESIGN-STANDARDS.md`, `docs/BUILDING.md` and `docs/parity/README.md` before changing code. Session state, execution prompts and historical agent reports are not product requirements; use the current task instructions and exact candidate evidence.

Every window, menu, toolbar, alert, status, colour, shortcut or wording change must meet the design standards and cite their rule ids. Design budgets only go down. Preserve all required capability coverage; a menu, inventory row or test count never proves complete behavior. Keep the compact per-capability requirement matrix and dated source/check mappings current when their paths change.

The integrator owns build files, bridge APIs, document lifecycle and the command catalogue; workers edit assigned paths. Scintilla owns one authoritative text model and Undo history. Preserve capture/revalidation, strict bytes, bounded work, private atomic storage and explicit external actions. No implicit shell or extension execution.

Keep public commits curated: no machine-private paths, proprietary reference implementation or credentials. No running-app GUI or real user data access without explicit task authorization. Run the isolated checks, inspect actual completion summaries, and report supported limitations. Every preview remains incomplete until all required behavior is verified.

Before building a release, fetch origin and reconcile the checkout with the accepted product revision. At delivery, commit and push reviewed changes, merge them to main, fetch again and verify the accepted commit is reachable from origin/main. Install the verified Release build at `/Applications/TextTank.app`, check its signature and contents against the build, then retire older runnable copies. Keep the commit, test results and installed bundle identity in the delivery record. Report any pending step explicitly.
