#!/usr/bin/env python3
"""Fails when PHP's test suite failed a test that is not a known failure.

Usage: check-php-tests.py RUNTIME_ID TEST_RESULTS_FILE SUITE_STATUS

TEST_RESULTS_FILE is run-tests.php's -W list, which run-tests creates when it
starts and fills with each test's result ("FAILED<tab>path"); expected
failures (XFAILED) and warnings don't count as failures. SUITE_STATUS is the exit status of
`make test` under run-bounded-check.py: non-zero when tests failed (PHP 8's
run-tests always reports it), 124 when the guard stopped the suite. Known
failures, each with its reason, are listed in php-known-failures.txt next to
this script.
"""
import pathlib
import sys


# run-tests' results that fail a suite; XFAILED, WARNED, SKIPPED and PASSED don't.
FAILURES = {"FAILED", "BORKED", "LEAKED"}


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
    runtime, results_file, status = sys.argv[1], pathlib.Path(sys.argv[2]), int(sys.argv[3])
    if status == 124:
        raise SystemExit(f"The {runtime} test suite was stopped by the test guard.")
    if not results_file.exists():
        raise SystemExit(f"The {runtime} test suite did not run (exit status {status}).")
    results = [line.split("\t", 1) for line in results_file.read_text(encoding="utf-8").splitlines() if "\t" in line]
    failed = [path.strip() for result, path in results if result in FAILURES]
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
    print(f"PHP test suite for {runtime}: {len(results)} tests, {len(failed)} known failure(s), no others.")


if __name__ == "__main__":
    main()
