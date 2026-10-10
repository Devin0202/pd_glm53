#!/usr/bin/env bash
# Run in foreground under bash -l; supervisor/nohup is the caller's choice.
#
# Usage: PD_TOPO="prefill=<label> decode=<label>,<label>..." ALLOW_LAUNCHER_PD=1 start.sh <role> <RUN_ID>
# Topology is never defaulted: the same PD_TOPO must be given on every node of a run.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
TOPO="$HERE/topology.py"
py() { python3 "$TOPO" "$@"; }
role=${1:?usage: start.sh prefill|decode|standalone RUN_ID}
profile=baseline262k
run_id=${2:?unique RUN_ID required}
[[ "$run_id" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Invalid RUN_ID'; exit 2; }
case "$role" in prefill|decode|standalone) ;; *) echo 'usage: start.sh prefill|decode|standalone RUN_ID'; exit 2 ;; esac
# Entry gate for every start: operator must confirm this node is released for PD duty.
[[ ${ALLOW_LAUNCHER_PD:-0} == 1 ]] || { echo 'Start blocked. Set ALLOW_LAUNCHER_PD=1 after confirming this node is free for PD (no benchmark or other service).'; exit 2; }
label=$(py local-label)
topo_role=$(py topology-role "$label")
# A node may only start the role this run's topology gives it; standalone borrows the
# prefill node because it is a single-engine comparison run, never a peer of PD.
if [[ "$role" == standalone ]]; then
 [[ "$topo_role" == prefill ]] || { echo "standalone runs on the topology's prefill node; $label is '$topo_role' in PD_TOPO"; exit 2; }
else
 [[ "$topo_role" == "$role" ]] || { echo "$label is '$topo_role' in PD_TOPO, not '$role'"; exit 2; }
fi
PD_ROOT=$(py root)
address=$(py node-ip "$label")
UCX_NET_DEVICES=$(py node-ucx "$label")
UCX_IB_GID_INDEX=$(py gid-index)
case "$role" in
 prefill) port=$(py port prefill); side=$(py side-port prefill) ;;
 decode) port=$(py port decode); side=$(py side-port decode) ;;
 standalone) port=$(py port prefill); side=$(py side-port prefill) ;;
esac
ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$address" || { echo "Configured IP $address for $label is absent locally"; exit 2; }
source /torch/venv3/pytorch_infer/bin/activate
# CNIXL 1.2.3 cannot register VMM/expandable segments.
export PYTORCH_MLU_ALLOC_CONF=expandable_segments:False
export VLLM_ENGINE_READY_TIMEOUT_S=1800
export PYTHONHASHSEED=0 VLLM_ENABLE_V1_MULTIPROCESSING=1 VLLM_WORKER_MULTIPROC_METHOD=spawn
export MLU_VISIBLE_DEVICES=0,1,2,3,4,5,6,7
export UCX_NET_DEVICES UCX_IB_GID_INDEX
# Refuse stale network mappings after a platform instance is replaced.
python - <<'PY'
import os
from pathlib import Path
for item in os.environ['UCX_NET_DEVICES'].split(','):
    device, port = item.split(':')
    root = Path('/sys/class/infiniband') / device / 'ports' / port
    gid = os.environ['UCX_IB_GID_INDEX']
    assert (root / 'gid_attrs/ndevs' / gid).read_text().strip().startswith('net')
    assert (root / 'gid_attrs/types' / gid).read_text().strip() == 'RoCE v2'
    assert ':ffff:' in (root / 'gids' / gid).read_text()
PY
export VLLM_NIXL_SIDE_CHANNEL_HOST=$address VLLM_NIXL_SIDE_CHANNEL_PORT=$side
# One foreground launcher per node. The lock is keyed by node, not role: three decode
# nodes share this filesystem and must not contend for one decode.lock. It is held until
# the child exits, so prefill and standalone on one node also exclude each other.
mkdir -p "$PD_ROOT/locks"
exec 9>"$(py lock-path "$label")"
flock -n 9 || { echo "This node ($label) already has a launcher"; exit 2; }
if pgrep -f '[v]llm serve|[b]ench_vllm.py|[r]un_dp2_adaptive.py' >/dev/null; then
 echo 'Existing serving/benchmark process detected; nothing stopped.'; exit 2
fi
# Refuse occupied devices even if they belong to a different application.
cnmon > /tmp/pd-cnmon-$$.txt
if ! python - /tmp/pd-cnmon-$$.txt <<'PY'
import re,sys
s=open(sys.argv[1]).read()
used=re.findall(r'(\d+)\s+MiB/\s*\d+\s+MiB',s)
assert len(used)==8 and all(int(x)==0 for x in used), 'Cards occupied or cnmon format unrecognized'
PY
then rm -f /tmp/pd-cnmon-$$.txt; exit 2; fi
rm -f /tmp/pd-cnmon-$$.txt
python - "$port" "$side" <<'PY'
import socket,sys
for port in (int(sys.argv[1]),int(sys.argv[2]),int(sys.argv[2])+1):
 with socket.socket() as s:
  s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
  s.bind(('0.0.0.0',port))
PY
run=$(py engine-dir "$run_id" "$role" "$label")
mkdir -p "$(dirname "$run")"
if [[ -e "$run" ]]; then echo "Run dir already exists: $run (never overwrite an earlier run)"; exit 2; fi
mkdir "$run"
# Cache is keyed by node as well: the three decode nodes share this filesystem and must
# not write one another's triton/vllm caches while they compile concurrently.
export XDG_CACHE_HOME="$PD_ROOT/cache/$profile/$role-$label"
export HF_HOME="$XDG_CACHE_HOME/huggingface" HUGGINGFACE_HUB_CACHE="$XDG_CACHE_HOME/huggingface/hub"
export TORCH_HOME="$XDG_CACHE_HOME/torch" VLLM_CACHE_ROOT="$XDG_CACHE_HOME/vllm"
export TRITON_CACHE_DIR="$XDG_CACHE_HOME/triton" TORCHINDUCTOR_CACHE_DIR="$XDG_CACHE_HOME/torchinductor"
mkdir -p "$XDG_CACHE_HOME"
cp "$HERE/configs/$role.yaml" "$run/config.yaml"
# configs/*.yaml are JSON. Only rewrite when the configured port differs, and then patch
# the one token textually so the file stays otherwise byte-identical.
python3 - "$run/config.yaml" "$port" <<'PY'
import json,re,sys,pathlib
path=pathlib.Path(sys.argv[1]); want=int(sys.argv[2])
text=path.read_text()
current=json.loads(text).get('port')
if current != want:
    patched,count=re.subn(r'^(\s*)"port":\s*\d+', lambda m: f'{m.group(1)}"port": {want}', text, count=1, flags=re.M)
    assert count==1, f'no "port" key to patch in {path}'
    path.write_text(patched)
    print(f'patched config port {current} -> {want}', file=sys.stderr)
PY
cp "$HERE/cluster.json" "$HERE/topology.py" "$HERE/start.sh" "$run/"
sha256sum "$run/config.yaml" "$run/start.sh" "$run/topology.py" "$run/cluster.json" > "$run/SHA256SUMS"
printf '%s\n' "profile=$profile" "role=$role" "label=$label" "instance=$(py instance)" \
 "host=$(hostname)" "side_channel=$address:$side" "topo=$PD_TOPO" > "$run/run.info"
echo "Starting $role/$profile on $label; log: $run/server.log"
# No global kill/cleanup: this wrapper owns only this exact child.
vllm serve --config "$run/config.yaml" > "$run/server.log" 2>&1 &
child=$!
printf '%s\n' "$child" > "$run/server.pid"
trap 'kill -TERM "$child" 2>/dev/null || true; wait "$child" || true' TERM INT
set +e
wait "$child"
rc=$?
printf '%s\n' "$rc" > "$run/exit_code"
exit "$rc"
