#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/cluster.env"
[[ $(hostname -s) == "$PREFILL_NODE" ]] || { echo "Run router on $PREFILL_NODE"; exit 2; }
[[ ${ALLOW_LAUNCHER_PD:-0} == 1 ]] || { echo 'Start blocked. Set ALLOW_LAUNCHER_PD=1 after confirming this node is free for PD (no benchmark or other service).'; exit 2; }
run_id=${1:?usage: router.sh SAME_RUN_ID_AS_BOTH_ENGINES}
[[ "$run_id" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 2
# The two starts must have used one matching profile and this shared run id.
python3 - "$PD_ROOT/runs/$run_id" <<'PY'
import json,sys
from pathlib import Path
r=Path(sys.argv[1]); p=json.loads((r/'prefill/config.yaml').read_text()); d=json.loads((r/'decode/config.yaml').read_text())
for k in ('model','tokenizer-mode','max-model-len','block-size','speculative-config','no-enable-prefix-caching'):
 assert p.get(k)==d.get(k), f'P/D mismatch: {k}'
PY
echo '2ee688193e800ac5a32eacb3dd12440ab49b31eb73b08a8ea80ff79aefe28e06  '"$HERE/bin/vllm-router" | sha256sum -c -
curl --fail --silent --show-error --max-time 10 "http://$PREFILL_HOST:8100/health"
curl --fail --silent --show-error --max-time 10 "http://$DECODE_HOST:8200/health"
run="$PD_ROOT/runs/$run_id/router"
mkdir "$run"
cp "$HERE/router.sh" "$HERE/cluster.env" "$run/"
chmod u+x "$HERE/bin/vllm-router"
echo "Router log: $run/router.log"
echo $$ > "$run/router.pid"
exec "$HERE/bin/vllm-router" \
 --policy round_robin --vllm-pd-disaggregation --kv-connector nixl \
 --prefill "http://$PREFILL_HOST:8100" --decode "http://$DECODE_HOST:8200" \
 --host 0.0.0.0 --port 8300 --request-timeout-secs 1800 \
 > "$run/router.log" 2>&1
