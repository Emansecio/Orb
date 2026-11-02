#!/bin/zsh
# Runs the tests with half of this Mac's cores: `scripts/test.sh --filter 'SuiteA|SuiteB'` (any `swift test` option passes
# through). Swift Testing otherwise runs as many tests at once as there are cores, and on 8 of them ~25 tests that wait on a
# clock or the main actor fail; one at a time (--no-parallel) the whole suite takes ~4 min. Half of the cores ran it in ~65 s
# with no extra failure in three runs (2026-11-02), and leaves the other half to whatever the person is doing.
# ORB_TEST_WIDTH=<n> picks another number of tests at once (1 is the same as --no-parallel).
set -euo pipefail
cd "$(dirname "$0")/.."

WIDTH="${ORB_TEST_WIDTH:-$(( $(sysctl -n hw.ncpu) / 2 ))}"
(( WIDTH >= 1 )) || WIDTH=1
# The documented knob is --num-workers, but it only reaches XCTest; Swift Testing reads this variable.
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="$WIDTH"
exec swift test "$@"
