#!/bin/bash
#
# mateinate test suite.
#
# Everything runs against fake pmset / ifconfig / sudo / launchctl / caffeinate
# binaries, so it never touches the real power management and works on any
# machine (including CI containers).
#
#   ./tests/run.sh          run all cases
#   KEEP=1 ./tests/run.sh   keep the scratch dir for poking around
#
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
CMD="$ROOT/mateinate"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mateinate-tests.XXXXXX")
DAEMON_PID=""
PASS=0
FAIL=0
FAILED=""

cleanup() {
  [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null
  [ -n "${DAEMON_PID:-}" ] && wait "$DAEMON_PID" 2>/dev/null
  if [ "${KEEP:-0}" = "1" ]; then
    echo "scratch dir: $TMP"
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT

ok() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}

bad() {
  FAIL=$((FAIL + 1))
  FAILED="$FAILED
  - $1"
  printf '  FAIL %s\n' "$1"
}

check_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi
}

check_contains() {
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1 (missing '$3' in: $2)" ;;
  esac
}

# --- fakes ------------------------------------------------------------------

make_fakes() {
  mkdir -p "$TMP/bin"
  cat >"$TMP/bin/pmset" <<'EOF'
#!/bin/bash
F=${FAKE:?FAKE not set}
case "${1:-}" in
  -g)
    if [ "${2:-}" = "batt" ]; then
      if [ -f "$F/ac" ]; then src="AC Power"; st="charging"; else src="Battery Power"; st="discharging"; fi
      printf "Now drawing from '%s'\n -InternalBattery-0 (id=1)\t%s%%; %s; 1:00 remaining present: true\n" \
        "$src" "$(cat "$F/pct" 2>/dev/null || echo 50)" "$st"
    else
      [ -f "$F/disablesleep" ] && echo " disablesleep $(cat "$F/disablesleep")"
      echo " sleep 0"
    fi
    ;;
  -a)
    if [ "${2:-}" = "disablesleep" ]; then printf '%s\n' "${3:-0}" >"$F/disablesleep"; fi
    ;;
esac
EOF

  cat >"$TMP/bin/ifconfig" <<'EOF'
#!/bin/bash
if [ -f "${FAKE:?}/wifi" ]; then
  printf "en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n"
  printf "\tinet 192.168.1.50 netmask 0xffffff00 broadcast 192.168.1.255\n"
  printf "\tstatus: active\n"
else
  printf "en0: flags=8822<BROADCAST,SMART,SIMPLEX,MULTICAST> mtu 1500\n\tstatus: inactive\n"
fi
EOF

  cat >"$TMP/bin/sudo" <<'EOF'
#!/bin/bash
F=${FAKE:?}
[ -f "$F/sudo-fail" ] && { echo "sudo: a password is required" >&2; exit 1; }
[ "${1:-}" = "-n" ] && shift
if [ "${1:-}" = "-l" ]; then
  echo "User may run the following commands:"
  [ -f "$F/nopasswd" ] && echo "    (root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
  exit 0
fi
exec "$@"
EOF

  cat >"$TMP/bin/launchctl" <<'EOF'
#!/bin/bash
F=${FAKE:?}
case "${1:-}" in
  print) [ -f "$F/agent-loaded" ] && exit 0 || exit 1 ;;
  bootstrap) : >"$F/agent-loaded" ;;
esac
exit 0
EOF

  cat >"$TMP/bin/caffeinate" <<'EOF'
#!/bin/bash
exec sleep 300
EOF

  cat >"$TMP/bin/id" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-u" ] && [ "${FAKE_UID:-}" = "0" ]; then echo 0; exit 0; fi
exec /usr/bin/id "$@"
EOF

  chmod +x "$TMP"/bin/*
  export PATH="$TMP/bin:$PATH"
}

# --- harness ----------------------------------------------------------------

new_case() {
  CASE="$TMP/$1"
  STATE="$CASE/state"
  mkdir -p "$CASE" "$STATE" "$CASE/home/Library/LaunchAgents"
  export HOME="$CASE/home"
  case "$HOME" in
    "$TMP"/*) ;;
    *)
      echo "refusing to run: HOME is outside the scratch dir ($HOME)" >&2
      exit 1
      ;;
  esac
  export FAKE="$STATE"
  export MATEINATE_STATE="$CASE/ma"
  export MATEINATE_LOG="$CASE/log"
  export MATEINATE_CONFIG="$CASE/config-does-not-exist"
  export PMSET="$TMP/bin/pmset"
  export IFCONFIG="$TMP/bin/ifconfig"
  export SUDO="$TMP/bin/sudo"
  export CAFFEINATE="$TMP/bin/caffeinate"
  export VISUDO="$TMP/bin/visudo"
  export GRACE=1 POLL=1 MODE=pmset WIFI_IFACE=en0
  touch "$STATE/wifi"
  echo 50 >"$STATE/pct"
  : >"$STATE/ac"
  DAEMON_PID=""
}

start_daemon() {
  "$CMD" run >>"$CASE/out" 2>&1 &
  DAEMON_PID=$!
}

stop_daemon() {
  [ -n "$DAEMON_PID" ] || return 0
  kill "$DAEMON_PID" 2>/dev/null
  wait "$DAEMON_PID" 2>/dev/null
  DAEMON_PID=""
}

lock_state() {
  cat "$STATE/disablesleep" 2>/dev/null || echo 0
}

wait_lock() { # expected, attempts (0.25s each)
  local i=0
  while [ "$i" -lt "${2:-16}" ]; do
    [ "$(lock_state)" = "$1" ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

# --- cases ------------------------------------------------------------------


make_fakes

new_case "ac-low-battery"
printf '%s\n' "case: holds with the charger connected even below the floor"
export FAKE_UID=""
echo 5 >"$STATE/pct"
start_daemon
if wait_lock 1; then ok "lock acquired"; else bad "lock acquired (got $(lock_state))"; fi
stop_daemon
check_eq "lock released on stop" "$(lock_state)" "0"

new_case "battery-ok"
printf '%s\n' "case: holds on battery above the floor"
echo 20 >"$STATE/pct"
rm -f "$STATE/ac"
start_daemon
if wait_lock 1; then ok "lock acquired"; else bad "lock acquired (got $(lock_state))"; fi
stop_daemon
check_eq "lock released on stop" "$(lock_state)" "0"

new_case "wifi-lost"
printf '%s\n' "case: releases after GRACE when Wi-Fi drops"
start_daemon
if wait_lock 1; then ok "lock acquired"; else bad "lock acquired (got $(lock_state))"; fi
rm -f "$STATE/wifi"
sleep 0.5
check_eq "still holding inside the grace window" "$(lock_state)" "1"
if wait_lock 0 24; then ok "released after grace"; else bad "released after grace (got $(lock_state))"; fi
stop_daemon
check_contains "logged the release" "$(cat "$CASE/log")" "sleep allowed"

new_case "battery-floor"
printf '%s\n' "case: releases when the battery reaches the floor on battery"
echo 20 >"$STATE/pct"
rm -f "$STATE/ac"
start_daemon
if wait_lock 1; then ok "lock acquired"; else bad "lock acquired (got $(lock_state))"; fi
echo 15 >"$STATE/pct"
if wait_lock 0 24; then ok "released at the floor"; else bad "released at the floor (got $(lock_state))"; fi
stop_daemon

new_case "no-sudo"
printf '%s\n' "case: no passwordless sudo means no hold, warned once"
: >"$STATE/sudo-fail"
start_daemon
sleep 2.5
check_eq "no lock without the rule" "$(lock_state)" "0"
check_eq "warned exactly once" "$(grep -c 'needs passwordless sudo' "$CASE/log")" "1"
rm -f "$STATE/sudo-fail"
if wait_lock 1 12; then ok "holds once the rule shows up"; else bad "holds once the rule shows up (got $(lock_state))"; fi
stop_daemon

new_case "watchdog"
printf '%s\n' "case: watchdog releases a lock left by a dead daemon"
mkdir -p "$CASE/ma"
echo 1 >"$STATE/disablesleep"
echo 999999 >"$CASE/ma/daemon.pid"
echo 1 >"$CASE/ma/heartbeat"
"$CMD" watchdog
check_eq "lock released by watchdog" "$(lock_state)" "0"
check_contains "watchdog logged it" "$(cat "$CASE/log" 2>/dev/null)" "watchdog"

new_case "stale-lock"
printf '%s\n' "case: clears a stale lock when it should not be holding"
mkdir -p "$CASE/ma"
echo 1 >"$STATE/disablesleep"
rm -f "$STATE/wifi"
start_daemon
if wait_lock 0 12; then ok "stale lock cleared"; else bad "stale lock cleared (got $(lock_state))"; fi
stop_daemon
check_contains "logged the cleanup" "$(cat "$CASE/log")" "cleared stale"

new_case "stop-command"
printf '%s\n' "case: 'stop' releases the lock and unloads the agents"
start_daemon
if wait_lock 1; then ok "lock acquired"; else bad "lock acquired (got $(lock_state))"; fi
DAEMON_PID_SAVED="$DAEMON_PID"
"$CMD" stop >"$CASE/stop.out" 2>&1
DAEMON_PID=""
check_eq "lock released by stop" "$(lock_state)" "0"
if kill -0 "$DAEMON_PID_SAVED" 2>/dev/null; then bad "daemon stopped"; else ok "daemon stopped"; fi

new_case "caffeinate-mode"
printf '%s\n' "case: caffeinate mode spawns and releases a holder"
export MODE=caffeinate
start_daemon
i=0
while [ "$i" -lt 16 ] && [ ! -f "$CASE/ma/caffeinate.pid" ]; do
  sleep 0.25
  i=$((i + 1))
done
CPID=$(cat "$CASE/ma/caffeinate.pid" 2>/dev/null)
if [ -n "${CPID:-}" ] && kill -0 "$CPID" 2>/dev/null; then ok "caffeinate running"; else bad "caffeinate running"; fi
stop_daemon
if [ -n "${CPID:-}" ] && kill -0 "$CPID" 2>/dev/null; then bad "caffeinate released"; else ok "caffeinate released"; fi
export MODE=pmset

new_case "install-paths"
printf '%s\n' "case: install records the stable entry point and both agents"
mkdir -p "$CASE/pathbin"
ln -sf "$CMD" "$CASE/pathbin/mateinate"
out=$(cd "$CASE" && PATH="$CASE/pathbin:$PATH" mateinate install 2>&1)
check_contains "install output" "$out" "installed and started"
if [ -f "$HOME/Library/LaunchAgents/com.mateinate.agent.plist" ]; then ok "daemon plist written"; else bad "daemon plist written"; fi
if [ -f "$HOME/Library/LaunchAgents/com.mateinate.agent.watchdog.plist" ]; then ok "watchdog plist written"; else bad "watchdog plist written"; fi
EXPECT="$(cd "$CASE/pathbin" && pwd -P)/mateinate"
check_contains "plist points at the entry point" "$(cat "$HOME/Library/LaunchAgents/com.mateinate.agent.plist" 2>/dev/null)" "$EXPECT"

new_case "root-guard"
printf '%s\n' "case: refuses to run as root"
export FAKE_UID=0
out=$("$CMD" start 2>&1)
rc=$?
export FAKE_UID=""
check_eq "exit code" "$rc" "1"
check_contains "explains why" "$out" "don't run 'mateinate start' with sudo"

new_case "cli"
printf '%s\n' "case: version, help and unknown commands"
check_eq "version" "$("$CMD" version)" "1.0.0"
check_contains "help" "$("$CMD" help)" "usage: mateinate"
check_contains "status runs" "$("$CMD" status)" "decision    :"
"$CMD" nope >/dev/null 2>&1
check_eq "unknown command exits 2" "$?" "2"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" != "0" ]; then
  printf 'failures:%s\n' "$FAILED"
  exit 1
fi
