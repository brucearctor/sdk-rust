#!/usr/bin/env bash
# Runs `cargo integ-test` repeatedly, capturing full output and shutdown-trace
# logs to ./repro_logs/run-NNN.log. When libtest prints the "has been running
# for over 60 seconds" line we treat the run as interesting but keep letting
# it proceed — tests normally finish in <40s so giving them up to ~90s lets
# us observe trailing shutdown traces without killing context.
#
# Only once a run has been stuck past a hard wall-clock ceiling (default 90s
# after the first slow-warn line) do we hard-kill the cargo process tree,
# snapshot some final diagnostics, and exit so you can inspect the log.
#
# Usage:
#   ./repro_slow_shutdown.sh               # loop forever
#   ./repro_slow_shutdown.sh 20            # at most 20 iterations
#   HARD_KILL_AFTER=120 ./repro_slow_shutdown.sh
#   TEST_FILTER=schedule_to_close ./repro_slow_shutdown.sh
#
# Environment:
#   HARD_KILL_AFTER — seconds AFTER the first libtest slow-warn line before
#                     we hard-kill the run. Default: 90.
#   TEST_FILTER     — optional substring filter passed to the test harness.
#   EXTRA_ARGS      — extra args forwarded to `cargo integ-test` (before --).
#   RUST_LOG        — passed through to cargo; defaults to info so the
#                     [SHUTDOWN_TRACE] warn! lines are captured.

set -u -o pipefail

MAX_ITERS="${1:-}"
HARD_KILL_AFTER="${HARD_KILL_AFTER:-90}"
LOG_DIR="$(pwd)/repro_logs"
mkdir -p "$LOG_DIR"

export RUST_LOG="${RUST_LOG:-info}"

cleanup_children() {
    pkill -TERM -P $$ 2>/dev/null || true
    pkill -TERM -f 'cargo.*integ-test' 2>/dev/null || true
    pkill -TERM -f 'integ_tests-'    2>/dev/null || true
    sleep 1
    pkill -KILL -f 'cargo.*integ-test' 2>/dev/null || true
    pkill -KILL -f 'integ_tests-'    2>/dev/null || true
    pkill -KILL -f 'temporal server' 2>/dev/null || true
}
trap 'echo; echo "[repro] interrupted"; cleanup_children; exit 130' INT TERM

iter=0
while :; do
    iter=$((iter + 1))
    if [[ -n "$MAX_ITERS" && $iter -gt $MAX_ITERS ]]; then
        echo "[repro] Completed $MAX_ITERS iterations without a hard-kill. Exiting."
        exit 0
    fi

    log="$LOG_DIR/run-$(printf '%03d' "$iter").log"
    sentinel="$LOG_DIR/run-$(printf '%03d' "$iter").slow-seen-at"
    rm -f "$sentinel"

    echo "[repro] === Iteration $iter — logging to $log ==="
    start=$SECONDS

    filter_args=()
    if [[ -n "${TEST_FILTER:-}" ]]; then
        filter_args+=("$TEST_FILTER")
    fi
    extra=(${EXTRA_ARGS:-})

    # Run cargo in its own process group so we can kill the whole tree.
    setsid cargo integ-test "${extra[@]}" -- "${filter_args[@]}" 2>&1 \
        | tee "$log" \
        | awk -v sentinel="$sentinel" '
            /test .* has been running for over [0-9]+ seconds/ {
                if (!seen) {
                    seen = 1
                    # Record wall-clock time so the bash watchdog can read it.
                    cmd = "date +%s"
                    cmd | getline now
                    close(cmd)
                    print now > sentinel
                    close(sentinel)
                    print "[repro] noticed slow-test warning: " $0 > "/dev/stderr"
                }
            }
            { print }
        ' > /dev/null &
    pipeline_pid=$!

    # Watchdog: if we ever see the sentinel and HARD_KILL_AFTER has elapsed
    # since it was written, hard-kill the pipeline and bail out.
    watchdog_tripped=0
    while kill -0 "$pipeline_pid" 2>/dev/null; do
        if [[ -f "$sentinel" ]]; then
            slow_at=$(cat "$sentinel" 2>/dev/null || echo 0)
            now=$(date +%s)
            age=$((now - slow_at))
            if (( age >= HARD_KILL_AFTER )); then
                echo "[repro] !!! Hard-kill: ${age}s past first slow-warn. Killing run."
                watchdog_tripped=1
                break
            fi
        fi
        sleep 2
    done

    if (( watchdog_tripped )); then
        cleanup_children
        # Give the killed processes a moment to flush their stderr into the log.
        sleep 2
        echo "[repro] Full log: $log"
        echo "[repro] Last 80 lines:"
        tail -n 80 "$log"
        echo
        echo "[repro] SHUTDOWN_TRACE lines from this run:"
        grep -n 'SHUTDOWN_TRACE\|Initiated shutdown\|shutdown_worker rpc completed\|has been running for over' "$log" || true
        exit 1
    fi

    # The cargo pipeline exited on its own — wait for it and move on.
    wait "$pipeline_pid" 2>/dev/null || true
    rc=${PIPESTATUS[0]:-0}
    elapsed=$((SECONDS - start))

    # If we saw a slow warning but the run still finished, log that — those
    # are the MOST interesting runs since we have traces from a slow shutdown
    # that actually completed.
    if [[ -f "$sentinel" ]]; then
        echo "[repro] Iteration $iter finished in ${elapsed}s AFTER a slow-test warning (rc=$rc)."
        echo "[repro] Keeping log: $log"
    elif (( rc != 0 )); then
        echo "[repro] Iteration $iter: cargo rc=$rc in ${elapsed}s — continuing."
    else
        echo "[repro] Iteration $iter: passed in ${elapsed}s."
    fi
done
