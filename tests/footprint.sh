#!/usr/bin/env bash
# Boots a headless Bee node and checks resident memory against budgets.
# Usage: tests/footprint.sh [binary] [rss_budget_mb] [live_heap_budget_mb]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$(realpath "${1:-$root/dist/bee}")"
rss_budget="${2:-190}"
heap_budget="${3:-42}"
settle_cycles="${SETTLE_CYCLES:-0}"
wait_limit="${WAIT_LIMIT:-120}"

work="$root/.wippy/footprint"
rm -rf "$work"
mkdir -p "$work/folder" "$work/config"
log="$work/node.log"

pid=""
cleanup() {
	if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
		kill -INT "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	fi
}
trap cleanup EXIT

cd "$work/folder"
XDG_CONFIG_HOME="$work/config" GODEBUG=gctrace=1 "$bin" node >"$log" 2>&1 &
pid=$!

# The node is up when it prints its running line; it is settled once the
# runtime has completed SETTLE_CYCLES further GC cycles after that line;
# an idle node may run none, so the default reads the last boot cycle.
deadline=$((SECONDS + wait_limit))
while ! grep -q "is running" "$log"; do
	kill -0 "$pid" 2>/dev/null || { echo "node exited before running" >&2; cat "$log" >&2; exit 2; }
	((SECONDS < deadline)) || { echo "node did not start in ${wait_limit}s" >&2; exit 2; }
	sleep 0.2
done

running_line="$(grep -n "is running" "$log" | head -1 | cut -d: -f1)"
while :; do
	cycles="$(tail -n +"$running_line" "$log" | grep -c '^gc ' || true)"
	((cycles >= settle_cycles)) && break
	kill -0 "$pid" 2>/dev/null || { echo "node exited while settling" >&2; exit 2; }
	((SECONDS < deadline)) || { echo "no GC cycles after start in ${wait_limit}s" >&2; exit 2; }
	sleep 0.2
done

rss_kb="$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status")"
rss_mb=$((rss_kb / 1024))
# gctrace "A->B->C MB": C is the live heap after the last completed mark.
heap_mb="$(grep '^gc ' "$log" | tail -1 | sed -E 's/.* ([0-9]+)->([0-9]+)->([0-9]+) MB.*/\3/')"

kill -INT "$pid"
wait "$pid" 2>/dev/null || true
pid=""

echo "rss_mb=$rss_mb budget=$rss_budget"
echo "live_heap_mb=$heap_mb budget=$heap_budget"

status=0
((rss_mb <= rss_budget)) || { echo "FAIL: RSS over budget" >&2; status=1; }
((heap_mb <= heap_budget)) || { echo "FAIL: live heap over budget" >&2; status=1; }
exit $status
