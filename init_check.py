#!/usr/bin/env python3
"""Report MLU, host memory and RoCE state on the cluster's nodes, and keep cluster.json
honest about how those nodes are actually reached.

Per node it prints one line: GPU state, host RAM, and the RoCE ports NIXL will use (MTU,
speed, link state). Detail appears only where it matters (occupied cards, unreachable nodes,
inventory drift, mixed MTU or a port that is not ACTIVE), so a healthy cluster is a few
short lines and a verdict.

Reaching a node: the IP cluster.json records is tried first; if that fails, the matching
~/.ssh/config entry is used instead. A node is matched to an ssh entry by role suffix - the
part of the label after the instance tag, e.g. worker-0 - because a platform rebuild
changes the instance tag in both files at once.

Staying honest: whichever target answers, the node reports its own hostname, eth0 IP and
RoCE device list, and cluster.json is corrected when any of them disagree (a rebuild
renames nodes and renumbers mlx5 ports). Use --no-update to only be told about it.

    python3 init_check.py
    python3 init_check.py --node u4f0c2-worker-1 --node u4f0c2-worker-2
    python3 init_check.py --no-update

Exit status: 0 every checked node is idle, 1 at least one card is occupied,
2 at least one node is unknown (unreachable, or its state could not be read).
"""
import argparse
import json
import pathlib
import socket
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import topology

EXPECTED_CARDS = 8
SSH_TIMEOUT = 90
SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]

# One python probe, run locally via `python3 -` and remotely via `ssh <target> python3 -`.
# It reports identity, host memory, MLU occupancy and valid RoCE devices together, so a
# single round trip answers both "is this node free" and "does cluster.json still describe it".
PROBE = r'''
import json, os, socket, subprocess, tempfile
from pathlib import Path
out = {}
out["hostname"] = socket.gethostname().split(".")[0]
try:
    addr = subprocess.run(["ip", "-o", "-4", "addr", "show", "eth0"],
                          capture_output=True, text=True, timeout=15)
    out["eth0_ip"] = addr.stdout.split()[3].split("/")[0] if addr.stdout.split() else None
except Exception as exc:
    out["eth0_ip"] = None
mem = {}
for line in Path("/proc/meminfo").read_text().splitlines():
    key, _, value = line.partition(":")
    if value.strip():
        mem[key] = int(value.split()[0])
out["mem_total_kb"] = mem.get("MemTotal")
out["mem_available_kb"] = mem.get("MemAvailable")
with tempfile.TemporaryDirectory() as tmp:
    proc = subprocess.run(["cnmon", "info", "-j"], cwd=tmp, capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        out["cnmon_error"] = (proc.stderr or proc.stdout).strip()[-200:] or f"exit {proc.returncode}"
    else:
        out["cards"] = json.loads(Path(tmp, "cnmon_info.json").read_text())["CnmonInfo"]
gid = os.environ.get("PD_GID_INDEX", "7")
def order(path):
    digits = path.name.split("_")[1]
    return int(digits) if digits.isdigit() else 1 << 30   # mlx5_bond_0 is not a numbered port
def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None
devices, roce = [], []
for dev in sorted(Path("/sys/class/infiniband").glob("mlx5_*"), key=order):
    root = dev / "ports" / "1"
    kind = read(root / "gid_attrs" / "types" / gid)
    value = read(root / "gids" / gid) or ""
    ndev = read(root / "gid_attrs" / "ndevs" / gid) or ""
    if kind == "RoCE v2" and ":ffff:" in value and ndev.startswith("net"):
        devices.append(dev.name + ":1")
        # RoCE has no IB port MTU: the MTU that carries the traffic is the backing netdev's.
        roce.append({"dev": dev.name, "netdev": ndev, "mtu": read("/sys/class/net/" + ndev + "/mtu"),
                     "speed": read(root / "rate"), "state": read(root / "state")})
out["ucx"] = ",".join(devices)
out["roce"] = roce
print(json.dumps(out))
'''


def ssh_config_hosts(path):
    """alias -> HostName (or None) from an ssh config. Wildcard patterns are ignored."""
    hosts = {}
    current = []
    try:
        text = path.read_text()
    except OSError as exc:
        return None, str(exc)
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        key, _, value = line.partition(" ")
        key = key.lower()
        if key == "host":
            current = [pat for pat in value.split() if not any(ch in pat for ch in "*?!")]
            for alias in current:
                hosts.setdefault(alias, {})
        elif key == "hostname" and current:
            for alias in current:
                hosts[alias]["hostname"] = value.strip()
    return {alias: info.get("hostname") for alias, info in hosts.items()}, None


def role_suffix(label, instance):
    """The part of a label that survives a rebuild: worker-0 out of u4f0c2-worker-0."""
    return label[len(instance) + 1:] if label.startswith(instance + "-") else label


def label_from_hostname(hostname, suffix):
    """u4f0c2-worker-0 from notebook-devenviron-0920-100724-u4f0c2-worker-0 + worker-0."""
    if not hostname.endswith("-" + suffix):
        return None
    head = hostname[: -(len(suffix) + 1)]
    return head.rsplit("-", 1)[-1] + "-" + suffix


def match_alias(label, suffix, hosts):
    """ssh entry for a node: its current label, or any alias with the same role suffix."""
    if label in hosts:
        return label
    for alias in sorted(hosts):
        if alias.endswith("-" + suffix):
            return alias
    return None


def probe(target, local):
    """Run the probe on the local node or over ssh. Returns (data, error)."""
    argv = ["python3", "-"] if local else ["ssh", *SSH_OPTS, target, "python3", "-"]
    try:
        proc = subprocess.run(argv, input=PROBE, capture_output=True, text=True, timeout=SSH_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None, f"timed out after {SSH_TIMEOUT}s"
    if proc.returncode != 0:
        lines = [line for line in proc.stderr.strip().splitlines() if line.strip()]
        return None, lines[-1] if lines else f"exit status {proc.returncode}"
    try:
        return json.loads(proc.stdout), None
    except json.JSONDecodeError as exc:
        return None, f"probe output is not JSON: {exc}"


def card_usage(card):
    """(used_mib, total_mib, util_percent) for one card; any of them may be None."""
    mem = card.get("PhysicalMemUsage") or {}
    util = card.get("Utilization") or {}
    busy = util.get("MLUAverage", util.get("CoreActivity"))
    try:
        busy = int(busy)
    except (TypeError, ValueError):
        busy = None
    return mem.get("Used"), mem.get("Total"), busy


def gib(kb):
    return "?" if kb is None else str(round(kb / 1024 / 1024))


def shorten(alias, limit=24):
    """Column-friendly alias: the platform prefix is noise, the tail identifies the node."""
    return alias if len(alias) <= limit else "…" + alias[-(limit - 1):]


def roce_summary(ports):
    """(table cell, anomaly lines) for one node's RoCE ports.

    MTU is the one that bites silently: NIXL picks its transfer size from the path MTU, so a
    single port left at 1500 among 4192 peers degrades or breaks that rank without an error.
    """
    if not ports:
        return "-", ["no RoCE port matches the configured GID index"]
    counts = {}
    for port in ports:
        counts[port["mtu"]] = counts.get(port["mtu"], 0) + 1
    mtus = sorted(counts, key=str)
    speeds = sorted({port["speed"].split()[0] if port["speed"] else "" for port in ports})
    readable = [port for port in ports if port["state"]]
    active = sum(1 for port in readable if port["state"].endswith("ACTIVE"))
    cell = (f"{'/'.join('?' if mtu is None else str(mtu) for mtu in mtus)} mtu, "
            f"{'/'.join(speed + 'G' if speed else '?' for speed in speeds)}, "
            + (f"{active}/{len(readable)} ACTIVE" if readable else "state ?"))
    problems = []
    if len(mtus) > 1:
        # Name only the odd ones: listing every port buries the answer.
        majority = max(counts, key=lambda mtu: counts[mtu])
        odd = [port for port in ports if port["mtu"] != majority]
        problems.append(f"mixed RoCE MTU (most are {majority}): " + ", ".join(
            f"{port['dev']}({port['netdev']})={port['mtu']}" for port in odd))
    unreadable = [port for port in ports if not port["state"]]
    if unreadable:
        problems.append("RoCE link state unreadable: " + ", ".join(port["dev"] for port in unreadable))
    down = [port for port in readable if not port["state"].endswith("ACTIVE")]
    if down:
        problems.append("RoCE port not ACTIVE: " + ", ".join(
            f"{port['dev']}={port['state']}" for port in down))
    if len(ports) != EXPECTED_CARDS:
        problems.append(f"{len(ports)} RoCE ports, expected {EXPECTED_CARDS} (one per MLU)")
    return cell, problems


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--node", action="append", default=[], metavar="LABEL",
                        help="only this node (repeatable); default is every node in cluster.json")
    parser.add_argument("--ssh-config", default="~/.ssh/config", metavar="PATH",
                        help="ssh config to fall back on and cross-check against cluster.json")
    parser.add_argument("--no-update", action="store_true",
                        help="report drift in cluster.json but do not rewrite it")
    args = parser.parse_args()

    try:
        cfg, cfg_path = topology.load_cluster()
    except topology.PdError as exc:
        print(exc, file=sys.stderr)
        return 2
    wanted = args.node or [entry["label"] for entry in cfg["nodes"]]
    try:
        for label in wanted:
            topology.node(cfg, label)
    except topology.PdError as exc:
        print(exc, file=sys.stderr)
        return 2

    ssh_path = pathlib.Path(args.ssh_config).expanduser()
    hosts, ssh_error = ssh_config_hosts(ssh_path)
    hosts = hosts or {}
    our_hostname = socket.gethostname().split(".")[0]

    print(f"cluster.json  {cfg_path}   instance={cfg['instance']}")
    if ssh_error:
        print(f"ssh config    {ssh_path}   ! {ssh_error}")
    else:
        print(f"ssh config    {ssh_path}   {len(hosts)} entries")

    rows, details = [], []
    observations, occupied, unknown, roce_flagged = [], [], [], []
    for entry in cfg["nodes"]:
        label = entry["label"]
        if label not in wanted:
            continue
        suffix = role_suffix(label, cfg["instance"])
        alias = match_alias(label, suffix, hosts)
        local = our_hostname.endswith("-" + suffix)
        # Short values only: a long alias would otherwise push the later columns out of line.
        targets = [("local", entry["ip"], True)] if local else [(entry["ip"], entry["ip"], False)]
        if alias is not None and not local:
            targets.append((f"ssh {shorten(alias)}", alias, False))
        # cluster.json first, ssh config as the fallback: that is the order of authority asked for.
        data = error = via = None
        for via, target, is_local in targets:
            data, error = probe(target, is_local)
            if data is not None:
                break
        if data is None:
            unknown.append(label)
            rows.append((label, "-", "UNKNOWN", "-", "-"))
            details.append(f"{label}: {error}")
            continue
        observations.append((entry, suffix, data))

        roce_cell, roce_problems = roce_summary(data.get("roce") or [])
        if roce_problems:
            roce_flagged.append(label)
            details.extend(f"{label}: {problem}" for problem in roce_problems)
        cards = data.get("cards")
        total_kb, avail_kb = data.get("mem_total_kb"), data.get("mem_available_kb")
        ram = f"{gib(total_kb - avail_kb)} / {gib(total_kb)} GiB" if total_kb and avail_kb is not None else "?"
        if cards is None:
            unknown.append(label)
            rows.append((label, via, "UNKNOWN", ram, roce_cell))
            details.append(f"{label}: {data.get('cnmon_error', 'no card data')}")
            continue
        usages = [card_usage(card) for card in cards]
        used = [value for value, _, _ in usages]
        if len(cards) != EXPECTED_CARDS or any(value is None for value in used):
            unknown.append(label)
            rows.append((label, via, "UNKNOWN", ram, roce_cell))
            details.append(f"{label}: saw {len(cards)} cards, expected {EXPECTED_CARDS} with readable memory")
            continue
        busy = [index for index, value in enumerate(used) if value > 0]
        if busy:
            occupied.append(label)
            rows.append((label, via, f"OCCUPIED {len(busy)}/{len(cards)}", ram, roce_cell))
            for index in busy:
                _, total, util = usages[index]
                share = f" ({round(100 * used[index] / total)}%)" if total else ""
                details.append(f"{label} card {index}: {used[index]} / {total} MiB{share}"
                               + (f", MLU busy {util}%" if util is not None else ""))
        else:
            rows.append((label, via, f"idle {len(cards)} cards", ram, roce_cell))

    header = ("node", "reached via", "gpu", "ram used/total", "roce")
    widths = [max(len(row[column]) for row in (header, *rows)) for column in range(len(header))]
    print()
    for row in (header, *rows):
        print("  ".join(cell.ljust(width) for cell, width in zip(row, widths)).rstrip())
    if details:
        print()
        for line in details:
            print(f"  ! {line}")

    # Identity as the nodes report it. Suffixes were captured before any label changed, so the
    # comparison stays valid while the inventory is being rewritten.
    corrections = []
    for entry, suffix, data in observations:
        observed = label_from_hostname(data.get("hostname") or "", suffix)
        if observed and observed != entry["label"]:
            corrections.append((entry, "label", entry["label"], observed))
        if data.get("eth0_ip") and data["eth0_ip"] != entry["ip"]:
            corrections.append((entry, "ip", entry["ip"], data["eth0_ip"]))
        if data.get("ucx") and data["ucx"] != entry["ucx"]:
            corrections.append((entry, "ucx", entry["ucx"], data["ucx"]))
    observed_instances = set()
    for entry, suffix, data in observations:
        corrected = label_from_hostname(data.get("hostname") or "", suffix)
        if corrected:
            observed_instances.add(corrected[: -(len(suffix) + 1)])
    if corrections:
        if args.no_update:
            print(f"\ncluster.json is stale ({len(corrections)} field(s)); rerun without --no-update to correct it:")
        else:
            for entry, field, _, new in corrections:
                entry[field] = new
            if len(observed_instances) == 1:
                cfg["instance"] = next(iter(observed_instances))
            cfg_path.write_text(json.dumps(cfg, indent=2) + "\n")
            print(f"\ncluster.json updated ({len(corrections)} field(s) taken from the nodes themselves):")
        for _, field, old, new in corrections:
            print(f"  {field}: {old} -> {new}")
        if not args.no_update and len(observed_instances) != 1:
            print(f"  ! nodes disagree on the instance tag; left instance={cfg['instance']}")

    checked = len(wanted)
    verdict = f"{checked - len(occupied) - len(unknown)} idle, {len(occupied)} occupied, {len(unknown)} unknown"
    if occupied:
        verdict += f" | occupied: {', '.join(occupied)}"
    if unknown:
        verdict += f" | unknown: {', '.join(unknown)}"
    if roce_flagged:
        verdict += f" | roce: {', '.join(roce_flagged)}"
    if corrections:
        verdict += " | cluster.json corrected" if not args.no_update else " | cluster.json stale"
    print(f"\nverdict: {verdict}")
    if unknown:
        return 2
    if occupied:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
