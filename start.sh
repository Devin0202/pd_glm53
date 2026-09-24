#!/usr/bin/env bash
# Run in foreground under bash -l; supervisor/nohup is the caller's choice.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/cluster.env"
role=${1:?usage: start.sh prefill|decode RUN_ID}
profile=baseline262k
run_id=${2:?unique RUN_ID required}
[[ "$run_id" =~ ^[a-zA-Z0-9_-]+$ ]] || { echo 'Invalid RUN_ID'; exit 2; }
# Entry gate for every start: operator must confirm this node is released for PD duty.
[[ ${ALLOW_LAUNCHER_PD:-0} == 1 ]] || { echo 'Start blocked. Set ALLOW_LAUNCHER_PD=1 after confirming this node is free for PD (no benchmark or other service).'; exit 2; }
case "$role" in
 prefill) expected=$PREFILL_NODE; address=$PREFILL_HOST; side=$PREFILL_SIDE_PORT; port=8100; UCX_NET_DEVICES=$PREFILL_UCX_NET_DEVICES ;;
 decode) expected=$DECODE_NODE; address=$DECODE_HOST; side=$DECODE_SIDE_PORT; port=8200; UCX_NET_DEVICES=$DECODE_UCX_NET_DEVICES ;;
 *) exit 2 ;;
esac
[[ $(hostname -s) == "$expected" ]] || { echo "Wrong node: expected $expected"; exit 2; }
ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$address" || { echo 'Configured local IP absent'; exit 2; }
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
# One foreground launcher per role. Lock is held until the child exits.
mkdir -p "$PD_ROOT/locks"
exec 9>"$PD_ROOT/locks/$role.lock"
flock -n 9 || { echo 'This role already has a launcher'; exit 2; }
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
run="$PD_ROOT/runs/$run_id/$role"
mkdir -p "$(dirname "$run")"
mkdir "$run" # Never overwrite an earlier run.
export XDG_CACHE_HOME="$PD_ROOT/cache/$role/$profile"
export HF_HOME="$XDG_CACHE_HOME/huggingface" HUGGINGFACE_HUB_CACHE="$XDG_CACHE_HOME/huggingface/hub"
export TORCH_HOME="$XDG_CACHE_HOME/torch" VLLM_CACHE_ROOT="$XDG_CACHE_HOME/vllm"
export TRITON_CACHE_DIR="$XDG_CACHE_HOME/triton" TORCHINDUCTOR_CACHE_DIR="$XDG_CACHE_HOME/torchinductor"
mkdir -p "$XDG_CACHE_HOME"
cp "$HERE/configs/$role.yaml" "$run/config.yaml"
cp "$HERE/cluster.env" "$run/cluster.env"
cp "$HERE/start.sh" "$run/start.sh"
sha256sum "$run/config.yaml" "$run/start.sh" > "$run/SHA256SUMS"
printf '%s\n' "profile=$profile" "host=$(hostname)" "side_channel=$address:$side" > "$run/run.info"
echo "Starting $role/$profile; log: $run/server.log"
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
