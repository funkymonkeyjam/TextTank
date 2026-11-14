# Independent configured Run and extension review

Reviewer: search worker, not Run author. Scoped source inspection of RunCore.swift/RunController.swift and independent inert-process probes. This does not certify the complete required extension interface.

## Findings and repairs

- P1: multiple result windows originally shared mutable pending output, allowing an old Apply button to apply a newer run's result. Author now invalidates the old button, clears pending and closes the prior result before a new run/result. Re-read those guards; native cross-window action testing remains integrator-owned.
- P2: Apply could target a retained but detached editor. Author added target.window guard alongside revision/read-only/selection checks.
- Process lifetime: original Process/FileHandle implementation returned after a bounded inherited-pipe wait, but could leave blocking reader tasks and descendants. Author replaced it with posix_spawn process groups, nonblocking bounded reads and anonymous temporary stdin. Parent exit with descendants that closed their pipes initially escaped cleanup; source now cleans remaining group members even after successful parent completion.

## Independently observed process probes

Compiled current RunCore.swift separately with a unique probe executable and macOS 14 target. Two explicit finite zsh commands spawned `/bin/sleep 4`, printed its PID and exited:

- Inherited output pipes: returned in approximately 0.61 seconds, truncated=true; the child PID was no longer present.
- Output redirected to /dev/null: returned in approximately 0.12 seconds, truncated=false; the child PID was no longer present.

Probes live under ignored build/tests/RunReviewProbe.swift. They neither touched user documents nor ran imported content. Source bounds combined captured stdout/stderr to 4 MiB and invokes argv without shell interpretation except explicit configured shell mode. Cancellation/timeout kills this run's process group; this is process lifecycle control, not a sandbox for hostile commands that deliberately leave the group.
