#!/usr/bin/env bash
# Usage: PD_TOPO="prefill=<label> decode=<label>,<label>..." ALLOW_LAUNCHER_PD=1 router.sh <RUN_ID> [pd|standalone]
# Starts one static router for the whole topology; run it on the topology's prefill node.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TOPO="$HERE/topology.py"
py() { python3 "$TOPO" "$@"; }
run_id=${1:?usage: router.sh RUN_ID [pd|standalone]}
mode=${2:-pd}
[[ "$run_id" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Invalid RUN_ID'; exit 2; }
[[ "$mode" == pd || "$mode" == standalone ]] || { echo 'mode must be pd or standalone'; exit 2; }
[[ ${ALLOW_LAUNCHER_PD:-0} == 1 ]] || { echo 'Start blocked. Set ALLOW_LAUNCHER_PD=1 after confirming this node is free for PD (no benchmark or other service).'; exit 2; }
label=$(py local-label)
prefill_nodes=($(py prefill-nodes))
decode_nodes=($(py decode-nodes))
[[ "$label" == "${prefill_nodes[0]}" ]] || { echo "Run the router on the topology's prefill node (${prefill_nodes[0]}), not $label"; exit 2; }
if [[ "$mode" == pd ]] && (( ${#decode_nodes[@]} == 0 )); then
 echo 'PD mode needs at least one decode node in PD_TOPO'; exit 2
fi
PD_ROOT=$(py root)
# Every decode must agree with the prefill on the keys that make the KV transfer valid
# (topology.py CONFIG_KEYS documents which, and which are deliberately not required). Missing
# configs also mean an engine never started.
if [[ "$mode" == pd ]]; then py check-configs "$run_id"; fi
echo '2ee688193e800ac5a32eacb3dd12440ab49b31eb73b08a8ea80ff79aefe28e06  '"$HERE/bin/vllm-router" | sha256sum -c -
for l in "${prefill_nodes[@]}"; do
 curl --fail --silent --show-error --max-time 10 "http://$(py node-ip "$l"):$(py port prefill)/health" \
  || { echo "prefill $l is not healthy"; exit 2; }
done
if [[ "$mode" == pd ]]; then
 for l in "${decode_nodes[@]}"; do
  curl --fail --silent --show-error --max-time 10 "http://$(py node-ip "$l"):$(py port decode)/health" \
   || { echo "decode $l is not healthy"; exit 2; }
 done
fi
run=$(py router-dir "$run_id")
mkdir -p "$(dirname "$run")"
if [[ -e "$run" ]]; then echo "Run dir already exists: $run (never overwrite an earlier run)"; exit 2; fi
mkdir "$run"
cp "$HERE/router.sh" "$HERE/cluster.json" "$HERE/topology.py" "$run/"
# Contract for verify.py: the endpoints this router is actually wired to.
py topology-json "$run_id" "$mode" > "$run/topology.json"
chmod u+x "$HERE/bin/vllm-router"
echo "Router log: $run/router.log"
echo $$ > "$run/router.pid"
# A second router on this node would only fight over the port. Separate lock file from
# the engine lock: the prefill engine holds node-<label>.lock for its whole lifetime.
mkdir -p "$PD_ROOT/locks"
exec 8>"$PD_ROOT/locks/router-$label.lock"
flock -n 8 || { echo "A router is already running on $label"; exit 2; }
if [[ "$mode" == pd ]]; then
 # --prefill/--decode are repeatable flags; one URL per flag, never comma-joined.
 pflags=(); for l in "${prefill_nodes[@]}"; do pflags+=(--prefill "http://$(py node-ip "$l"):$(py port prefill)"); done
 dflags=(); for l in "${decode_nodes[@]}"; do dflags+=(--decode "http://$(py node-ip "$l"):$(py port decode)"); done
 exec "$HERE/bin/vllm-router" \
  --policy round_robin --vllm-pd-disaggregation --kv-connector nixl \
  ${pflags[@]+"${pflags[@]}"} ${dflags[@]+"${dflags[@]}"} \
  --host 0.0.0.0 --port "$(py port router)" --request-timeout-secs 1800 \
  > "$run/router.log" 2>&1
else
 # Regular reverse-proxy mode: front the standalone engine so clients keep one entry.
 exec "$HERE/bin/vllm-router" \
  --policy round_robin --worker-urls "http://$(py node-ip "${prefill_nodes[0]}"):$(py port prefill)" \
  --host 0.0.0.0 --port "$(py port router)" --request-timeout-secs 1800 \
  > "$run/router.log" 2>&1
fi
