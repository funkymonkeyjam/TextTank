#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Keep the suite command and its evidence writer inside one owned deadline."""
import os
import signal
import subprocess
import sys
import time


# The shell stays alive until both pipeline members finish. tee has time to flush and
# report its own exit when the deadline signal stops the suite and inherited writers.
PIPELINE = r'''
trap '' ALRM
log=$1
status_file=$2
shift 2
(trap - ALRM; exec "$@") 2>&1 | tee "$log"
statuses=("${PIPESTATUS[@]}")
printf '%s %s\n' "${statuses[0]}" "${statuses[1]}" > "$status_file"
'''


class Interrupted(Exception):
    def __init__(self, signo):
        self.signo = signo


def interrupt(signo, _frame):
    raise Interrupted(signo)


def signal_owned(group, signo):
    try:
        os.killpg(group.pid, signo)
    except (ProcessLookupError, PermissionError):
        # Darwin may return EPERM when only an exited session leader remains.
        if group.poll() is None:
            raise
        return False
    return True


def stop(group, signo):
    # The child remains our unreaped session leader until the final signal. Its
    # process group cannot be reused during cleanup. An already exited/reaped
    # group is never signaled again. Detached processes are outside this group.
    if signal_owned(group, signo):
        time.sleep(0.25)
        signal_owned(group, signal.SIGKILL)
    group.wait()


def main():
    seconds, log, status_file, *command = sys.argv[1:]
    pending = None
    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)

    def remember(signo, _frame):
        nonlocal pending
        pending = signo

    # Defer external cancellation until the new session has a bound leader.
    for signo in signals:
        signal.signal(signo, remember)
    limit = int(seconds)
    group = subprocess.Popen(
        ["/bin/bash", "-c", PIPELINE, "suite-pipeline", log, status_file, *command],
        start_new_session=True,
    )
    try:
        for signo in signals:
            signal.signal(signo, interrupt)
        if pending is not None:
            raise Interrupted(pending)
        return group.wait(timeout=limit if limit else None)
    except (subprocess.TimeoutExpired, Interrupted) as error:
        # A second external signal must not interrupt the short cleanup.
        for signo in signals:
            signal.signal(signo, signal.SIG_IGN)
        signo = signal.SIGALRM if isinstance(error, subprocess.TimeoutExpired) else error.signo
        stop(group, signo)
        return 128 + signo


if __name__ == "__main__":
    sys.exit(main())
