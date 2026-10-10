#!/usr/bin/env bash
# Stop what start.sh started on THIS node, plus the router if this node is the one running it.
#
# Mirrors start.sh: run it on each node you started, with the same RUN_ID. Nothing is killed
# by name or from a remembered PID - the PID recorded in the run directory is re-checked
# against /proc/<pid>/cmdline first, so a recycled PID can never be signalled by mistake.
# A run-wide pkill is never used: leftovers are reported with their PIDs for a human to judge.
#
# Usage: stop.sh <RUN_ID> [all|router|engine] [--force] [--drain-timeout SECS]
#   all      (default) stop the router here, then this node's engine
#   router   only the router
#   engine   only this node's engine
#   --force  skip draining and stop immediately
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TOPO="$HERE/topology.py"
py() { python3 "$TOPO" "$@"; }
die() { printf '%s\n' "$1" >&2; exit "${2:-2}"; }

if (( $# == 0 )); then
  echo 'usage: stop.sh RUN_ID [all|router|engine] [--force] [--drain-timeout SECS]' >&2
  exit 2
fi
run_id=$1
shift
target=all
force=0
drain_timeout=120
while (( $# )); do
  case $1 in
    all|router|engine) target=$1 ;;
    --force) force=1 ;;
    --drain-timeout) shift; drain_timeout=${1:?--drain-timeout needs a number of seconds} ;;
    *) die "unknown argument: $1"
  esac
  shift
done
[[ "$run_id" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid RUN_ID: $run_id"
[[ "$drain_timeout" =~ ^[0-9]+$ ]] || die "--drain-timeout needs a number of seconds, got: $drain_timeout"

label=$(py local-label)
PD_ROOT=$(py root)
run_root="$PD_ROOT/runs/$run_id"
[[ -d "$run_root" ]] || die "No such run on this filesystem: $run_root"

# Identity check: only signal a PID whose command line proves it belongs to this run.
pid_matches() { # PID NEEDLE...
  local pid=$1; shift
  [[ -r /proc/$pid/cmdline ]] || return 1
  local cmdline needle
  cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline") || return 1
  for needle in "$@"; do
    [[ $cmdline == *"$needle"* ]] || return 1
  done
}

signal_run_process() { # PIDFILE NAME NEEDLE...
  # 0 = TERM sent, 1 = nothing to signal, 2 = refused because the PID is not this run's.
  # Callers must only wait for an exit after a 0: waiting on somebody else's PID would hang.
  local pidfile=$1 name=$2; shift 2
  if [[ ! -f "$pidfile" ]]; then
    echo "  $name: no pid file ($pidfile); never started here?"
    return 1
  fi
  local pid
  pid=$(cat "$pidfile")
  if [[ ! -e /proc/$pid ]]; then
    echo "  $name: pid $pid is not running (exited earlier)"
    return 1
  fi
  if ! pid_matches "$pid" "$@"; then
    echo "  $name: REFUSING to signal pid $pid - its command line does not match this run" >&2
    echo "        $(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" >&2
    return 2
  fi
  echo "  $name: TERM pid $pid"
  kill -TERM "$pid"
}

wait_gone() { # PID SECONDS NAME
  local pid=$1 deadline=$(( SECONDS + $2 ))
  while (( SECONDS < deadline )); do
    if [[ ! -e /proc/$pid ]]; then
      echo "  $3: exited"
      return 0
    fi
    sleep 2
  done
  echo "  $3: still alive after $2s (pid $pid)" >&2
  return 1
}

# Which engine does this node hold for this run? The directory name carries the role.
engine_role=""
engine_dir=""
for candidate in "$run_root/prefill-$label" "$run_root/decode-$label" "$run_root/standalone"; do
  if [[ -d "$candidate" ]]; then
    engine_dir=$candidate
    engine_role=$(basename "${candidate%-$label}")
  fi
done
# Ports belong to this node's engine, not to the requested target: compute them here so the
# report below works even when only the router was asked for.
port=""
side=""
if [[ -n "$engine_dir" ]]; then
  port_role=$engine_role
  [[ $engine_role == standalone ]] && port_role=prefill
  port=$(py port "$port_role")
  side=$(py side-port "$port_role")
fi

# The router lives on the topology's prefill node. Its pid file is on the shared filesystem,
# where the PID means nothing, so only act on it when this node is the one running it.
router_dir="$run_root/router"
router_here=0
if [[ -f "$router_dir/topology.json" ]]; then
  router_ip=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["router"]["ip"])' "$router_dir/topology.json")
  if [[ "$router_ip" == "$(py node-ip "$label")" ]]; then router_here=1; fi
fi

echo "run $run_id on $label (target: $target)"
rc=0

# 1. Router first: stopping it is what keeps new work from reaching the engines.
if [[ $target == all || $target == router ]]; then
  if (( router_here )); then
    if signal_run_process "$router_dir/router.pid" "router" "vllm-router"; then
      wait_gone "$(cat "$router_dir/router.pid")" 60 router || rc=1
    else
      status=$?
      if (( status == 2 )); then rc=2; fi
    fi
  elif [[ -d "$router_dir" ]]; then
    echo "  router: runs on $router_ip, not on this node; stop it there"
  else
    echo "  router: never started for this run"
  fi
fi

# 2. Drain this node's engine, then stop it.
if [[ $target == all || $target == engine ]]; then
  if [[ -z "$engine_dir" ]]; then
    echo "  engine: no prefill/decode/standalone directory for $label in this run"
  else
    pidfile="$engine_dir/server.pid"
    drained=1
    if (( force )); then
      echo "  engine ($engine_role): --force, not waiting for the queue"
    elif [[ ! -f "$pidfile" ]]; then
      echo "  engine ($engine_role): no pid file, nothing to drain"
    elif [[ ! -e /proc/$(cat "$pidfile") ]]; then
      echo "  engine ($engine_role): process is gone, nothing to drain"
    else
      url="http://$(py node-ip "$label"):$port/metrics"
      deadline=$(( SECONDS + drain_timeout ))
      while :; do
        # `|| true` matters: under `set -e` + pipefail a curl that cannot connect (exit 7, which
        # is the normal state while the engine is still loading) would abort the whole script
        # before it can report anything. An empty reading is a case to report, not to die on.
        running=$(curl -s --max-time 5 "$url" | awk '/^vllm:num_requests_running/ {print $2; exit}' || true)
        if [[ -z "$running" ]]; then
          echo "  engine ($engine_role): cannot read $url; stop with --force if it is really down" >&2
          drained=0
          break
        fi
        if awk -v value="$running" 'BEGIN {exit !(value + 0 == 0)}'; then
          echo "  engine ($engine_role): drained, no requests running"
          break
        fi
        if (( SECONDS >= deadline )); then
          echo "  engine ($engine_role): still $running request(s) after ${drain_timeout}s; not stopping it" >&2
          echo "        wait for the load to finish, or rerun with --force to cut it off" >&2
          drained=0
          break
        fi
        sleep 3
      done
    fi
    if (( drained )); then
      if signal_run_process "$pidfile" "engine ($engine_role)" "vllm" "serve" "$engine_dir/config.yaml"; then
        wait_gone "$(cat "$pidfile")" 180 "engine ($engine_role)" || rc=1
      else
        status=$?
        if (( status == 2 )); then rc=2; fi
      fi
    else
      rc=2
    fi
  fi
fi

# 3. Report the state this host is actually in now; start.sh's guards check exactly these.
echo "after stop:"
if [[ -n "$engine_dir" ]]; then
  python3 - "$port" "$side" <<'PY'
import socket, sys
for port in (int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[2]) + 1):
    with socket.socket() as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("0.0.0.0", port))
        except OSError as exc:
            print(f"  port {port}: still in use ({exc.strerror})")
        else:
            print(f"  port {port}: free")
PY
fi
python3 - "$HERE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import init_check
data, error = init_check.probe("local", True)
if data is None:
    print(f"  cards: unreadable ({error})")
else:
    used = [(card.get("PhysicalMemUsage") or {}).get("Used") for card in data.get("cards") or []]
    busy = [index for index, value in enumerate(used) if value]
    print(f"  cards: {len(used)} seen, " + (f"still holding memory on {busy}: {[used[i] for i in busy]} MiB"
                                          if busy else "all 0 MiB"))
PY

# Children of the engine can outlive the parent. Report them, never kill them by pattern,
# and only when this invocation was asked to stop that engine in the first place.
if [[ ( $target == all || $target == engine ) && -n "$engine_dir" ]]; then
  leftovers=$(pgrep -af "vllm serve --config $run_id" 2>/dev/null | grep -v '^$' || true)
  if [[ -n "$leftovers" ]]; then
    echo "WARNING: processes of this run are still alive; inspect before signalling them:" >&2
    echo "$leftovers" >&2
    rc=1
  fi
fi
exit "$rc"
