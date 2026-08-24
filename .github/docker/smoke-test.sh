#!/bin/bash
# Smoke tests run inside the release build, against the freshly built binary.
# These are cheap and they guard against shipping a binary that is broken in a
# way `make` cannot see. The config-save test in particular is a regression test
# for a SIGSEGV that got all the way to review: write_config() dispatches on the
# option's callback pointer, so a new setter that is not registered there is
# type-punned and passed to strlen(). It crashed on default settings, on every
# gekko build, whether or not the new flag was used.
set -euo pipefail

CGMINER="${1:?usage: smoke-test.sh /path/to/cgminer}"
API_PORT=4028
CONF=/tmp/smoke-out.conf

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
pass() { echo "  ok  $*"; }

echo "== 1. binary runs and reports a version"
"$CGMINER" --version || fail "--version exited non-zero"
pass "--version"

echo "== 2. --gekko-ticket-diff is registered with the documented default"
HELP="$("$CGMINER" --help 2>&1 || true)"
grep -q -- '--gekko-ticket-diff' <<<"$HELP" || fail "--gekko-ticket-diff missing from --help"
grep -A2 -- '--gekko-ticket-diff' <<<"$HELP" | grep -qi 'default: 1' \
    || fail "--gekko-ticket-diff default is not 1"
pass "--gekko-ticket-diff present, default 1"

echo "== 3. argument validation"
for good in 0 1 16 64; do
    "$CGMINER" --gekko-ticket-diff "$good" --version >/dev/null 2>&1 \
        || fail "valid ticket-diff $good was rejected"
done
pass "accepts 0 1 16 64"
for bad in 0.5 100 -1 nan; do
    if "$CGMINER" --gekko-ticket-diff "$bad" --version >/dev/null 2>&1; then
        fail "invalid ticket-diff $bad was accepted"
    fi
done
pass "rejects 0.5 100 -1 nan"

echo "== 4. config save does not crash (regression: write_config type-pun SIGSEGV)"
rm -f "$CONF"
"$CGMINER" --benchmark -T \
    --api-listen --api-allow "W:127.0.0.1" --api-port "$API_PORT" \
    > /tmp/smoke-cgminer.log 2>&1 &
CGPID=$!
trap 'kill -9 "$CGPID" 2>/dev/null || true' EXIT

# QEMU-emulated startup is slow; poll rather than sleeping a fixed amount.
for _ in $(seq 1 60); do
    if (exec 3<>/dev/tcp/127.0.0.1/"$API_PORT") 2>/dev/null; then
        exec 3<&- 3>&-
        break
    fi
    sleep 1
done

kill -0 "$CGPID" 2>/dev/null || fail "cgminer died before the API came up"

exec 3<>/dev/tcp/127.0.0.1/"$API_PORT" || fail "could not reach the API"
printf 'save|%s' "$CONF" >&3
API_REPLY="$(timeout 30 cat <&3 || true)"
exec 3<&- 3>&- || true

sleep 2
kill -0 "$CGPID" 2>/dev/null || fail "cgminer CRASHED on config save -- reply was: ${API_REPLY:-<none>}"
grep -q 'STATUS=S' <<<"$API_REPLY" || fail "config save reported failure: ${API_REPLY:-<none>}"
[ -s "$CONF" ] || fail "config save wrote no bytes"
grep -q 'gekko-ticket-diff' "$CONF" || fail "gekko-ticket-diff missing from the saved config"
pass "config save: $(wc -c < "$CONF") bytes, $(grep -o '"gekko-ticket-diff" : "[^"]*"' "$CONF")"

kill "$CGPID" 2>/dev/null || true
trap - EXIT
echo "SMOKE OK"
