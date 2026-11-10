#!/bin/zsh
# Runs the tests: `scripts/test.sh --filter 'SuiteA|SuiteB'` (any `swift test` option passes through).
#
# Width: ORB_TEST_WIDTH=<n> sets how many tests run at once in total (default: one per core split among the shards, half
# of the cores in a single process; 1 is the same as --no-parallel). Swift Testing reads
# SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH; SwiftPM's --num-workers only reaches XCTest.
#
# Shards: one process has one main actor, and @MainActor tests queue on it: with 8 tests at once in one process ~25 tests
# that wait on a clock or the main actor failed. So the whole suite (no --filter) is split by suite into ORB_TEST_SHARDS
# processes (default 4) that share the width, each with its own main actor. Measured 2026-11-10 on 8 cores: one process
# with 4 at once ~82 s; 4 processes with 2 each ~60 s, with no failure; one at a time ~4 min. A filtered run stays one
# process. ORB_TEST_SHARDS=1 keeps one process; ORB_TEST_SHARD=<i>/<n> runs only shard i of n (1-based), as the CI does.
set -euo pipefail
cd "$(dirname "$0")/.."

# `swift test --no-parallel 2>&1 | scripts/test.sh --record-times` rewrites scripts/test-times.txt from a serial run.
if [[ "${1:-}" == --record-times ]]; then
  { sed -n 1,2p scripts/test-times.txt
    sed -n -E 's/^[^ ]+ Suite ([A-Za-z0-9_]+) (passed|failed) after ([0-9.]+) seconds.*/\1 \3/p' | sort -u -k1,1; } > scripts/test-times.txt.new
  mv scripts/test-times.txt.new scripts/test-times.txt
  exit
fi

CORES="$(sysctl -n hw.ncpu)"
SHARDS="${ORB_TEST_SHARDS:-4}"
ONLY="${ORB_TEST_SHARD:-}"

# A filtered or listing run is small: one process, as before.
if (( ${@[(I)--filter*]} || ${@[(I)list]} || ${@[(I)--no-parallel]} )) || { [[ -z "$ONLY" ]] && (( SHARDS <= 1 )); }; then
  WIDTH="${ORB_TEST_WIDTH:-$(( CORES / 2 ))}"
  export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="$(( WIDTH > 0 ? WIDTH : 1 ))"
  exec swift test "$@"
fi

if [[ -n "$ONLY" ]]; then
  INDEX="${ONLY%/*}"; SHARDS="${ONLY#*/}"
  [[ "$INDEX" == <1-> && "$SHARDS" == <1-> ]] && (( INDEX <= SHARDS )) || { echo "ORB_TEST_SHARD deve ser i/n, com 1 ≤ i ≤ n" >&2; exit 2; }
fi

WIDTH="${ORB_TEST_WIDTH:-$CORES}"
(( WIDTH >= 1 )) || WIDTH=1
(( ${@[(I)--skip-build]} )) || swift build --build-tests
ARGS=("${(@)@:#--skip-build}")

# Suites are dealt to the shards slowest first, each to the one with the least time so far: a suite stays in one process
# (its .serialized tests and shared fixtures keep working). The time of a suite comes from scripts/test-times.txt (alone,
# in series); a suite missing there counts 0.04 s per test. Everything is sorted first so every CI job computes the same split.
FILTERS=("${(@f)$(swift test list --skip-build 2>/dev/null | sed -n 's#^OrbAppTests\.\([A-Za-z0-9_]*\)/.*#\1#p' | sort | uniq -c \
  | awk 'NR == FNR { if ($1 !~ /^#/) time[$1] = $2; next } { print ($2 in time ? time[$2] : $1 * 0.04), $2 }' scripts/test-times.txt - \
  | sort -k1,1gr -k2,2 | awk -v n="$SHARDS" '
    { best = 1; for (i = 2; i <= n; i++) if (load[i] < load[best]) best = i
      load[best] += $1; list[best] = list[best] (list[best] ? "|" : "") $2 }
    END { for (i = 1; i <= n; i++) print "^OrbAppTests\\.(" list[i] ")/" }')}")
(( ${#FILTERS} == SHARDS )) || { echo "Não consegui listar os testes para dividir." >&2; exit 1; }

if [[ -n "$ONLY" ]]; then
  WIDTH="${ORB_TEST_WIDTH:-$(( CORES / 2 ))}"
  export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="$(( WIDTH > 0 ? WIDTH : 1 ))"
  exec swift test --skip-build --filter "${FILTERS[$INDEX]}" "${ARGS[@]}"
fi

# Several `swift test` at once: --ignore-lock lets them share .build, which nothing writes after the build above.
export SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH="$(( WIDTH / SHARDS > 0 ? WIDTH / SHARDS : 1 ))"
LOGS="$(mktemp -d)"
PIDS=()
for i in {1..$SHARDS}; do
  swift test --skip-build --ignore-lock --filter "${FILTERS[$i]}" "${ARGS[@]}" > "$LOGS/$i.log" 2>&1 &
  PIDS+=($!)
done
trap 'kill ${PIDS[@]} 2>/dev/null || true' INT TERM
STATUS=0
for i in {1..$SHARDS}; do wait "${PIDS[$i]}" || STATUS=1; done

# The interleaved output of the shards would be unreadable: show what failed (and the issues recorded for it), then one
# summary line per shard. The full logs stay in $LOGS.
grep -h -E '^. (Test|Suite) .*( failed after| recorded an issue)' "$LOGS"/*.log | grep -v 'Test run with' || true
for i in {1..$SHARDS}; do
  print -r -- "parte $i/$SHARDS: $(grep -E 'Test run with|error:' "$LOGS/$i.log" | tail -n 1)"
done
print -r -- "Logs completos em $LOGS"
exit $STATUS
