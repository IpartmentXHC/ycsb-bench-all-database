#!/usr/bin/env python3
import argparse
import csv
import os
import signal
import subprocess
import time
from collections import defaultdict


STOP = False


def handle_signal(_signum, _frame):
    global STOP
    STOP = True


def load_cpu_nodes():
    out = subprocess.check_output(
        ["lscpu", "-e=CPU,NODE,ONLINE"], text=True, stderr=subprocess.DEVNULL
    )
    mapping = {}
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 3 or parts[2].lower() != "yes":
            continue
        mapping[int(parts[0])] = int(parts[1])
    return mapping


def read_proc_stat():
    stats = {}
    with open("/proc/stat", "r", encoding="utf-8") as fh:
        for line in fh:
            if not line.startswith("cpu") or not line[3:4].isdigit():
                continue
            parts = line.split()
            cpu = int(parts[0][3:])
            vals = [int(v) for v in parts[1:]]
            idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
            stats[cpu] = (idle, sum(vals))
    return stats


def main():
    parser = argparse.ArgumentParser(description="Sample per-NUMA-node CPU busy from /proc/stat.")
    parser.add_argument("--out", required=True)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--max-seconds", type=float, default=1800.0)
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    cpu_to_node = load_cpu_nodes()
    nodes = sorted(set(cpu_to_node.values()))
    os.makedirs(os.path.dirname(args.out), exist_ok=True)

    prev = read_proc_stat()
    start = time.time()
    fields = ["ts", "elapsed_s"] + [f"node{node}_busy_pct" for node in nodes]

    with open(args.out, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        while not STOP and time.time() - start < args.max_seconds:
            time.sleep(args.interval)
            now = read_proc_stat()
            node_busy = defaultdict(int)
            node_total = defaultdict(int)
            for cpu, node in cpu_to_node.items():
                if cpu not in prev or cpu not in now:
                    continue
                prev_idle, prev_total = prev[cpu]
                idle, total = now[cpu]
                total_delta = total - prev_total
                idle_delta = idle - prev_idle
                if total_delta <= 0:
                    continue
                node_total[node] += total_delta
                node_busy[node] += max(total_delta - idle_delta, 0)
            prev = now

            row = {
                "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "elapsed_s": f"{time.time() - start:.3f}",
            }
            for node in nodes:
                total = node_total[node]
                busy = 100.0 * node_busy[node] / total if total else 0.0
                row[f"node{node}_busy_pct"] = f"{busy:.6f}"
            writer.writerow(row)
            fh.flush()


if __name__ == "__main__":
    main()
