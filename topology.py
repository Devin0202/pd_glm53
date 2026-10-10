#!/usr/bin/env python3
"""Topology resolver for the pd_glm53 deployment package.

Single source of truth for the node inventory (cluster.json), the per-launch topology
(PD_TOPO), where each engine writes its run directory, and which lock a node takes.
start.sh and router.sh call this instead of parsing configuration in bash.

PD_TOPO is required on every launch and has no default. It names the topology this
particular start belongs to, using node labels from cluster.json:

    PD_TOPO="prefill=u4f0c2-launcher-0 decode=u4f0c2-worker-0,u4f0c2-worker-1"

Run `topology.py --help` for the subcommands, or `topology.py <cmd> --help` for one.
"""
import argparse
import json
import os
import pathlib
import socket
import sys

HERE = pathlib.Path(__file__).resolve().parent


class PdError(Exception):
    """Configuration or topology problem: reported on stderr, exit status 2."""


def port_key(role):
    return {"prefill": "prefill_http", "decode": "decode_http", "router": "router"}[role]


def side_key(role):
    return {"prefill": "prefill_side", "decode": "decode_side"}[role]


def load_cluster():
    path = pathlib.Path(os.environ.get("PD_CLUSTER", str(HERE / "cluster.json")))
    try:
        cfg = json.loads(path.read_text())
    except FileNotFoundError:
        raise PdError(f"cluster config not found: {path}")
    except json.JSONDecodeError as exc:
        raise PdError(f"cluster config is not valid JSON ({path}): {exc}")
    for key in ("instance", "pd_root", "nodes", "ports", "ucx_ib_gid_index"):
        if key not in cfg:
            raise PdError(f"cluster config {path}: missing '{key}'")
    if not cfg["nodes"]:
        raise PdError(f"cluster config {path}: no nodes listed")
    seen = set()
    for entry in cfg["nodes"]:
        for key in ("label", "ip", "ucx"):
            if not entry.get(key):
                raise PdError(f"cluster config {path}: node record missing '{key}': {entry}")
        if entry["label"] in seen:
            raise PdError(f"cluster config {path}: duplicate node label '{entry['label']}'")
        seen.add(entry["label"])
    return cfg, path


def node(cfg, label):
    for entry in cfg["nodes"]:
        if entry["label"] == label:
            return entry
    known = ", ".join(entry["label"] for entry in cfg["nodes"])
    raise PdError(f"unknown node label '{label}' (known: {known})")


def local_label(cfg):
    """This node's label: `hostname -s` from the instance tag onwards."""
    host = socket.gethostname().split(".")[0]
    tag = cfg["instance"]
    if tag not in host:
        raise PdError(
            f"stale inventory: hostname '{host}' does not contain instance tag '{tag}'. "
            "Re-derive cluster.json for this instance."
        )
    label = host[host.index(tag):]
    node(cfg, label)
    return label


def parse_topo(cfg):
    """Resolve PD_TOPO into (prefill_labels, decode_labels). No default on purpose."""
    topo = os.environ.get("PD_TOPO", "")
    if not topo.strip():
        raise PdError(
            "PD_TOPO is required, e.g. "
            'PD_TOPO="prefill=u4f0c2-launcher-0 decode=u4f0c2-worker-0,u4f0c2-worker-1"'
        )
    if '"' in topo or "\\" in topo:
        raise PdError("PD_TOPO must not contain quotes or backslashes")
    prefill = decode = None
    for token in topo.split():
        key, sep, value = token.partition("=")
        if not sep:
            raise PdError(f"PD_TOPO: expected key=value, got '{token}'")
        if key == "prefill":
            prefill = [item for item in value.split(",") if item]
        elif key == "decode":
            decode = [item for item in value.split(",") if item]
        else:
            raise PdError(f"PD_TOPO: unknown key '{key}' (expected prefill or decode)")
    if prefill is None:
        raise PdError("PD_TOPO: missing prefill=...")
    if decode is None:
        raise PdError("PD_TOPO: missing decode=... (write decode= for none)")
    if not prefill:
        raise PdError("PD_TOPO: no prefill nodes given")
    seen = []
    for label in prefill + decode:
        node(cfg, label)
        if label in seen:
            raise PdError(f"PD_TOPO: '{label}' is listed more than once")
        seen.append(label)
    return prefill, decode


def resolve_suffix(cfg, suffix):
    """Map a role suffix (worker-0) to the current label (bgsfqe-worker-0).

    Topologies are written in suffixes because a platform rebuild changes the instance tag
    in every label at once; the suffix is the part that survives.
    """
    matches = [entry["label"] for entry in cfg["nodes"] if entry["label"].endswith("-" + suffix)]
    if not matches:
        raise PdError(f"no node matches suffix '{suffix}' (known: {', '.join(e['label'] for e in cfg['nodes'])})")
    if len(matches) > 1:
        raise PdError(f"suffix '{suffix}' is ambiguous: {', '.join(matches)}")
    return matches[0]


def topology_roles(cfg, name):
    """Resolve a named topology from cluster.json into {role: [label, ...]}."""
    topologies = cfg.get("topologies")
    if not topologies:
        raise PdError("cluster config has no 'topologies' section")
    if name not in topologies:
        raise PdError(f"unknown topology '{name}' (defined: {', '.join(sorted(topologies))})")
    spec = topologies[name]
    roles = {}
    for role in ("prefill", "decode"):
        suffixes = spec.get(role)
        if not suffixes:
            raise PdError(f"topology '{name}' lists no {role} nodes")
        roles[role] = [resolve_suffix(cfg, suffix) for suffix in suffixes]
    return roles


def topology_role(cfg, label):
    prefill, decode = parse_topo(cfg)
    if label in prefill:
        return "prefill"
    if label in decode:
        return "decode"
    raise PdError(f"node '{label}' is not part of PD_TOPO ({os.environ.get('PD_TOPO', '')})")


def engine_dir(cfg, run_id, role, label):
    root = cfg["pd_root"]
    if role in ("prefill", "decode"):
        return f"{root}/runs/{run_id}/{role}-{label}"
    if role == "standalone":
        return f"{root}/runs/{run_id}/standalone"
    raise PdError(f"unknown role '{role}'")


def topology_dict(cfg, run_id, mode):
    prefill, decode = parse_topo(cfg)
    if mode == "standalone":
        # The router is wired to the single engine only, so that is what we record.
        decode = []
    return {
        "instance": cfg["instance"],
        "run_id": run_id,
        "mode": mode,
        "topo": os.environ.get("PD_TOPO", ""),
        "router": {"ip": node(cfg, prefill[0])["ip"], "port": cfg["ports"]["router"]},
        "prefill": [
            {
                "label": label,
                "ip": node(cfg, label)["ip"],
                "port": cfg["ports"]["prefill_http"],
                "side": cfg["ports"]["prefill_side"],
            }
            for label in prefill
        ],
        "decode": [
            {
                "label": label,
                "ip": node(cfg, label)["ip"],
                "port": cfg["ports"]["decode_http"],
                "side": cfg["ports"]["decode_side"],
            }
            for label in decode
        ],
    }


CONFIG_KEYS = (
    "model",
    "tokenizer-mode",
    "max-model-len",
    "block-size",
    "speculative-config",
    "no-enable-prefix-caching",
)


def read_config(path):
    if not pathlib.Path(path).exists():
        raise PdError(f"engine has not started yet (missing {path})")
    return json.loads(pathlib.Path(path).read_text())


def check_configs(cfg, run_id):
    """Every decode engine must match the prefill engine on the keys that PD requires."""
    prefill, decode = parse_topo(cfg)
    reference = read_config(pathlib.Path(engine_dir(cfg, run_id, "prefill", prefill[0])) / "config.yaml")
    for label in decode:
        candidate = read_config(pathlib.Path(engine_dir(cfg, run_id, "decode", label)) / "config.yaml")
        for key in CONFIG_KEYS:
            if reference.get(key) != candidate.get(key):
                raise PdError(
                    f"P/D config mismatch on '{key}': prefill {reference.get(key)!r} "
                    f"vs decode {label} {candidate.get(key)!r}"
                )


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("local-label", help="this node's label from the instance tag onwards")
    sub.add_parser("root", help="PD_ROOT")
    sub.add_parser("instance", help="platform instance tag")
    sub.add_parser("gid-index", help="UCX_IB_GID_INDEX")
    sub.add_parser("prefill-nodes", help="labels of the topology's prefill nodes, one per line")
    sub.add_parser("decode-nodes", help="labels of the topology's decode nodes, one per line")

    p = sub.add_parser("node-ip", help="eth0 IP of a node"); p.add_argument("label")
    p = sub.add_parser("node-ucx", help="RDMA device list of a node"); p.add_argument("label")
    p = sub.add_parser("topology-role", help="prefill/decode role of a node in PD_TOPO"); p.add_argument("label")
    p = sub.add_parser("lock-path", help="lock file this node takes"); p.add_argument("label")
    p = sub.add_parser("port", help="HTTP port for a role"); p.add_argument("role", choices=["prefill", "decode", "router"])
    p = sub.add_parser("side-port", help="NIXL side-channel port for a role"); p.add_argument("role", choices=["prefill", "decode"])
    p = sub.add_parser("router-dir", help="run directory for the router"); p.add_argument("run_id")

    p = sub.add_parser("engine-dir", help="run directory for one engine")
    p.add_argument("run_id"); p.add_argument("role", choices=["prefill", "decode", "standalone"]); p.add_argument("label")

    p = sub.add_parser("topology-json", help="resolved topology as JSON (verify.py contract)")
    p.add_argument("run_id"); p.add_argument("mode", choices=["pd", "standalone"])

    p = sub.add_parser("check-configs", help="assert every decode config matches the prefill config")
    p.add_argument("run_id")

    p = sub.add_parser("topo-string", help="named topology as a PD_TOPO string")
    p.add_argument("name")
    p = sub.add_parser("topo-labels", help="labels of one role in a named topology, one per line")
    p.add_argument("name"); p.add_argument("role", choices=["prefill", "decode"])

    args = parser.parse_args()
    cfg, _ = load_cluster()
    try:
        if args.cmd == "local-label":
            print(local_label(cfg))
        elif args.cmd == "root":
            print(cfg["pd_root"])
        elif args.cmd == "instance":
            print(cfg["instance"])
        elif args.cmd == "gid-index":
            print(cfg["ucx_ib_gid_index"])
        elif args.cmd == "prefill-nodes":
            print("\n".join(parse_topo(cfg)[0]))
        elif args.cmd == "decode-nodes":
            print("\n".join(parse_topo(cfg)[1]))
        elif args.cmd == "node-ip":
            print(node(cfg, args.label)["ip"])
        elif args.cmd == "node-ucx":
            print(node(cfg, args.label)["ucx"])
        elif args.cmd == "topology-role":
            print(topology_role(cfg, args.label))
        elif args.cmd == "lock-path":
            print(f"{cfg['pd_root']}/locks/node-{args.label}.lock")
        elif args.cmd == "port":
            print(cfg["ports"][port_key(args.role)])
        elif args.cmd == "side-port":
            print(cfg["ports"][side_key(args.role)])
        elif args.cmd == "router-dir":
            print(f"{cfg['pd_root']}/runs/{args.run_id}/router")
        elif args.cmd == "engine-dir":
            print(engine_dir(cfg, args.run_id, args.role, args.label))
        elif args.cmd == "topology-json":
            print(json.dumps(topology_dict(cfg, args.run_id, args.mode), indent=2))
        elif args.cmd == "check-configs":
            check_configs(cfg, args.run_id)
        elif args.cmd == "topo-string":
            roles = topology_roles(cfg, args.name)
            print(f"prefill={','.join(roles['prefill'])} decode={','.join(roles['decode'])}")
        elif args.cmd == "topo-labels":
            print("\n".join(topology_roles(cfg, args.name)[args.role]))
    except PdError as exc:
        print(exc, file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
