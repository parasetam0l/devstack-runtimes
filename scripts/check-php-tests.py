#!/usr/bin/env python3
"""Fails when PHP's test suite failed a test that is not a known failure.

Usage: check-php-tests.py RUNTIME_ID FAILED_TESTS_FILE SUITE_STATUS

FAILED_TESTS_FILE is run-tests.php's -w list, which run-tests creates when it
starts and fills with failed tests. SUITE_STATUS is the exit status of
`make test` under run-bounded-check.py: non-zero when tests failed (PHP 8's
run-tests always reports it), 124 when the guard stopped the suite. Known
failures, each with its reason, are listed in php-known-failures.txt next to
this script.
"""
import pathlib
import sys


def known_failures(runtime):
    known = {}
    listing = pathlib.Path(__file__).with_name("php-known-failures.txt")
    for line in listing.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        runtimes, test, reason = line.split(None, 2)
        if runtime in runtimes.split(","):
            known[test] = reason
    return known


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__.strip())
    runtime, failed_file, status = sys.argv[1], pathlib.Path(sys.argv[2]), int(sys.argv[3])
    if status == 124:
        raise SystemExit(f"The {runtime} test suite was stopped by the test guard.")
    if not failed_file.exists():
        raise SystemExit(f"The {runtime} test suite did not run (exit status {status}).")
    failed = [line.strip() for line in failed_file.read_text(encoding="utf-8").splitlines() if line.strip()]
    if status != 0 and not failed:
        raise SystemExit(f"The {runtime} test suite failed (exit status {status}) without reporting a failed test.")
    known = known_failures(runtime)
    if "*" in known:
        # A legacy runtime whose suite is recorded, not enforced.
        for path in failed:
            print(f"Recorded failure: {path}")
        print(f"PHP test suite for {runtime}: {len(failed)} failure(s) recorded ({known['*']}).")
        return
    unexpected = []
    for path in failed:
        test = next((test for test in known if path == test or path.endswith("/" + test)), None)
        if test is None:
            unexpected.append(path)
        else:
            print(f"Known failure: {test} ({known[test]})")
    if unexpected:
        print(f"{len(unexpected)} unexpected PHP test failure(s):", file=sys.stderr)
        for path in unexpected:
            print(f"  {path}", file=sys.stderr)
        raise SystemExit(1)
    print(f"PHP test suite for {runtime}: {len(failed)} known failure(s), no others.")


if __name__ == "__main__":
    main()
