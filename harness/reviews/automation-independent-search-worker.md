# Independent automation/connector/macro review

Reviewer: search worker, not feature author. Source review of AutomationController, RemindersConnector and MacroController; author-owned tests and review record report execution counts separately.

P1 repaired: a multiple-selection editor originally entered the multi-selection replacement branch for workflows whose configured output was external/new-document. That could mutate the editor despite the saved output action. Branch now explicitly requires selection input and editor output. Author added a multi-selection document→newDocument preservation regression.

P2 repaired: single-editor output lacked a read-only guard. The controller now rejects before mutation. Existing revision, attachment and captured-selection checks remain intact. Progress transformations capture snapshots and return through the main thread; ordinary recipe cleanup remains direct with a separate explicit Reminders action.

Responsiveness repair: recorded macro chunks were count-only, potentially allowing fifty 100ms search operations before the Stop button could respond. Playback now yields between steps after 20ms wall time. A single bounded search can still take its individual budget.

Connector inspection: nonblocking process lock covers concurrent connector instances; each row is durably marked uncertain before an external save. Uncertain/confirmed rows are not automatically retried, known no-write failures are explicit and pending rows remain resumable. Per-row yield allows cancellation. This review did not mutate EventKit or certify live revoked/deleted-list behavior; the user's confirmed live happy path remains separate evidence. Power-loss filesystem durability and adversarial ancestor-directory swaps were not exercised by this review.
