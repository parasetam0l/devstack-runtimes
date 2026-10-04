#!/usr/bin/env python3
"""Run a build-host check in an isolated process group with resource limits."""
import argparse
import os
import re
import resource
import signal
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=600)
    parser.add_argument("--rss-mb", type=int, default=1024)
    # Per process, which includes the test runner itself: a slow runner on a
    # long suite needs more than a single test.
    parser.add_argument("--cpu-seconds", type=int, default=60)
    # Growth above the wired memory at start: an absolute ceiling trips at
    # once on a Mac that already wires more than that while idle.
    parser.add_argument("--wired-mb", type=int, default=4096,
                        help="maximum growth of system wired memory during the check")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required")

    def limits():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        # Limit an individual runaway test, including children of the test runner.
        resource.setrlimit(resource.RLIMIT_CPU, (args.cpu_seconds, args.cpu_seconds + 5))

    def wired_bytes():
        memory = subprocess.check_output(["/usr/bin/vm_stat"], text=True)
        page_size = int(re.search(r"page size of (\d+) bytes", memory)[1])
        return int(re.search(r"Pages wired down:\s+(\d+)", memory)[1]) * page_size

    wired_at_start = wired_bytes() if sys.platform == "darwin" else 0
    process = subprocess.Popen(command, start_new_session=True, preexec_fn=limits)
    deadline = time.monotonic() + args.seconds
    aborted = None

    def stop(signum=None, frame=None):
        nonlocal aborted
        aborted = aborted or "interrupted"
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    try:
        while process.poll() is None and not aborted:
            if time.monotonic() >= deadline:
                aborted = "time limit exceeded"
                break
            rows = subprocess.check_output(["/bin/ps", "-axo", "pgid=,rss="], text=True)
            rss = sum(int(row.split()[1]) for row in rows.splitlines()
                      if row.split() and int(row.split()[0]) == process.pid)
            if rss > args.rss_mb * 1024:
                aborted = "test process memory limit exceeded"
                break
            if sys.platform == "darwin" and wired_bytes() - wired_at_start > args.wired_mb * 1024**2:
                aborted = "system wired-memory growth limit exceeded"
                break
            time.sleep(0.5)
    finally:
        # A successful test runner can still leave debugger children alive.
        try:
            os.killpg(process.pid, signal.SIGTERM)
            time.sleep(0.2)
            rows = subprocess.check_output(["/bin/ps", "-axo", "pgid=,stat="], text=True)
            if any(row.split() and int(row.split()[0]) == process.pid and not row.split()[1].startswith("Z")
                   for row in rows.splitlines()):
                os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
    if aborted:
        print("Check stopped: " + aborted, file=sys.stderr)
        return 124
    return process.returncode


if __name__ == "__main__":
    sys.exit(main())
