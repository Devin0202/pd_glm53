#!/usr/bin/env bash
# Drive a whole PD topology from one node: start every engine and then the router, or stop them.
#
# start.sh / router.sh / stop.sh stay per-node and unchanged; this script only decides which
# node plays which role (from the named topology in cluster.json) and reaches the others over
# ssh, using the eth0 IP that init_check.py keeps current.
#
# Usage: deploy.sh start|stop [--topo NAME] [--run-id ID] [--force] [--health-timeout SECS]
#   --topo NAME         deployment shape from cluster.json (default 1p3d; also 1p1d)
#   --run-id ID         reuse an existing id (start) or pick which run to stop
#   --force             stop: skip draining   start: unused
#   --health-timeout    seconds to wait per engine before giving up (default 1800)
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TOPO="$HERE/topology.py"
py() { python3 "$TOPO" "$@"; }
die() { printf '%s\n' "$1" >&2; exit "${2:-2}"; }
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)

action=${1:-}
case $action in
  start|stop) shift ;;
  *) die 'usage: deploy.sh start|stop [--topo NAME] [--run-id ID] [--force] [--health-timeout SECS]' ;;
esac
topo_name=1p3d
run_id=""
force=0
drain_timeout=""
health_timeout=1800
while (( $# )); do
  case $1 in
    --topo) shift; topo_name=${1:?--topo needs a name} ;;
    --run-id) shift; run_id=${1:?--run-id needs a value} ;;
    --force) force=1 ;;
    --drain-timeout) shift; drain_timeout=${1:?--drain-timeout needs seconds} ;;
    --health-timeout) shift; health_timeout=${1:?--health-timeout needs seconds} ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

PD_ROOT=$(py root)
topo_string=$(py topo-string "$topo_name")
mapfile -t prefills < <(py topo-labels "$topo_name" prefill)
mapfile -t decodes < <(py topo-labels "$topo_name" decode)
router_node=${prefills[0]}
router_ip=$(py node-ip "$router_node")
prefill_port=$(py port prefill)
decode_port=$(py port decode)
router_port=$(py port router)
log_dir="$PD_ROOT/logs"
mkdir -p "$log_dir"

launch_log() { printf '%s/%s-%s-%s.launch.log\n' "$log_dir" "$run_id" "$2" "$1"; }

remote() { # LABEL SCRIPT
  local ip
  ip=$(py node-ip "$1")
  printf '%s\n' "$2" | ssh "${SSH_OPTS[@]}" "$ip" bash -s
}

# start.sh and router.sh run in the foreground for the lifetime of the engine, so the remote
# command has to detach them and return. Keep `cd` on its own line, end with an explicit
# `exit 0`, and redirect all three streams: `cd X && cmd &` backgrounds a subshell that keeps
# holding the ssh channel, and the ssh session then never returns.
detach_engine() { # LABEL ROLE
  printf "cd '%s' || exit 1\nPD_TOPO='%s' ALLOW_LAUNCHER_PD=1 setsid nohup bash -l '%s/start.sh' '%s' '%s' > '%s' 2>&1 < /dev/null &\nexit 0\n" \
    "$HERE" "$topo_string" "$HERE" "$2" "$run_id" "$(launch_log "$1" "$2")"
}

detach_router() { # LABEL
  printf "cd '%s' || exit 1\nPD_TOPO='%s' ALLOW_LAUNCHER_PD=1 setsid nohup bash -l '%s/router.sh' '%s' > '%s' 2>&1 < /dev/null &\nexit 0\n" \
    "$HERE" "$topo_string" "$HERE" "$run_id" "$(launch_log "$1" router)"
}

# Where the engine itself logs (start.sh/router.sh write this, the launch log above only
# ever holds the wrapper's first line).
service_log() { # LABEL NAME(prefill|decode|router)
  if [[ $2 == router ]]; then
    printf '%s/router.log\n' "$(py router-dir "$run_id")"
  else
    printf '%s/server.log\n' "$(py engine-dir "$run_id" "$2" "$1")"
  fi
}

wait_http() { # LABEL PORT NAME PATH EXPECTATION(200|any)
  local label=$1 port=$2 name=$3 path=$4 expect=$5 ip code deadline log
  ip=$(py node-ip "$label")
  deadline=$(( SECONDS + health_timeout ))
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$ip:$port$path" || true)
    if [[ $expect == any && $code != 000 ]] || [[ $expect == 200 && $code == 200 ]]; then
      echo "  $name $label: up (http $code)"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      echo "  $name $label: not up after ${health_timeout}s (last http $code)" >&2
      # Show both: the wrapper's log says it was asked to start, the engine's log says why it did not.
      for log in "$(launch_log "$label" "$name")" "$(service_log "$label" "$name")"; do
        if [[ -f $log ]]; then echo "  --- tail of $log ---" >&2; tail -n 12 "$log" >&2; echo "  ---" >&2; fi
      done
      return 1
    fi
    sleep 10
  done
}

if [[ $action == start ]]; then
  [[ ${ALLOW_LAUNCHER_PD:-0} == 1 ]] || die 'Start blocked. Set ALLOW_LAUNCHER_PD=1 after confirming every node in this topology is free.'
  if [[ -z $run_id ]]; then run_id="deploy_$(date -u +%Y%m%d_%H%M%S)"; fi
  [[ $run_id =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid RUN_ID: $run_id"
  echo "topology: $topo_name  ->  $topo_string"
  echo "run id:   $run_id"
  echo
  echo "preflight (must be idle everywhere; cluster.json is corrected as a side effect):"
  # No --no-update here on purpose: the launch below ssh's to the recorded IPs, so a stale
  # inventory has to be brought up to date before anything is started.
  if ! python3 "$HERE/init_check.py"; then
    die 'Preflight failed: a node is occupied or unreachable. Nothing was started.'
  fi
  echo
  echo "launching engines:"
  for label in "${decodes[@]}"; do
    remote "$label" "$(detach_engine "$label" decode)"
    echo "  decode $label: requested"
  done
  # Every prefill of the topology, not just the one hosting the router: with 2P1D the
  # second prefill is a separate node and was never launched (the health wait below then
  # blocked until it timed out).
  for label in "${prefills[@]}"; do
    remote "$label" "$(detach_engine "$label" prefill)"
    echo "  prefill $label: requested"
  done
  # Record the run as soon as engines exist, not once they are healthy: a start that fails
  # later still leaves processes behind, and `deploy.sh stop` finds them through this file.
  printf '%s\n' "$run_id" > "$HERE/last_run"
  echo
  echo "waiting for engines (per-node timeout ${health_timeout}s):"
  for label in "${prefills[@]}"; do wait_http "$label" "$prefill_port" prefill /health 200 || die "prefill $label never became healthy; inspect $log_dir"; done
  for label in "${decodes[@]}"; do wait_http "$label" "$decode_port" decode /health 200 || die "decode $label never became healthy; inspect $log_dir"; done
  echo
  echo "launching router on $router_node:"
  remote "$router_node" "$(detach_router "$router_node")"
  wait_http "$router_node" "$router_port" router /get_loads any || die "router never answered; inspect $log_dir"
  echo
  echo "deployed: $topo_name, run $run_id"
  echo "  entry point: http://$router_ip:$router_port/v1   (model glm-5.3)"
  echo "  smoke test:  ROUTER=http://$router_ip:$router_port bash /workspace/volume/data/dy/plg/glm_chat.sh '你好'"
  echo "  stop it:     bash $HERE/deploy.sh stop --topo $topo_name"
  exit 0
fi

# stop
if [[ -z $run_id ]]; then
  [[ -f "$HERE/last_run" ]] || die "No --run-id given and nothing recorded in $HERE/last_run"
  run_id=$(cat "$HERE/last_run")
  echo "no --run-id given; using the last deployed run: $run_id"
fi
extra=""
(( force )) && extra="--force"
[[ -n $drain_timeout ]] && extra="$extra --drain-timeout $drain_timeout"
echo "stopping topology: $topo_name  run $run_id"
echo
# Router first: it is what keeps handing new work to the engines being drained below.
echo "router ($router_node):"
if ! remote "$router_node" "cd '$HERE' && bash stop.sh '$run_id' router $extra"; then
  echo "  (router stop reported a problem; continuing with the engines)" >&2
fi
rc=0
for label in "${prefills[@]}" "${decodes[@]}"; do
  echo
  echo "engine ($label):"
  remote "$label" "cd '$HERE' && bash stop.sh '$run_id' engine $extra" || rc=1
done
echo
if (( rc == 0 )); then echo "stopped: $topo_name, run $run_id"; else echo "stop finished with problems; see above" >&2; fi
exit "$rc"
