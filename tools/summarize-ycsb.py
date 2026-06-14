#!/usr/bin/env python3
import argparse
import csv
import math
import os
import re
import statistics
from collections import defaultdict
from pathlib import Path


def read_text(path):
    try:
        return Path(path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def fnum(value, default=0.0):
    try:
        if value in (None, ""):
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def metric(text, op, key):
    prefix = f"[{op}], {key},"
    value = ""
    for line in text.splitlines():
        if line.startswith(prefix):
            value = line.split(",")[-1].strip()
    return value


def parse_status_line_p999(text):
    value = 0.0
    for line in text.splitlines():
        match = re.search(r"99\.9=([0-9.]+)", line)
        if match:
            value = max(value, fnum(match.group(1)))
    return value


def count_errors(text):
    count = 0
    for line in text.splitlines():
        if "DBWrapper: report latency for each error" in line:
            continue
        if re.search(
            r"Exception|Error in database operation|DBException|SQL.*Exception|Connection refused|failed|timeout",
            line,
            re.I,
        ):
            count += 1
        match = re.match(r"\[[A-Z]+\], Return=([^,]+),\s*([0-9]+)", line)
        if match and match.group(1) != "OK":
            count += int(match.group(2))
    return count


def parse_client(path):
    text = read_text(path)
    p99 = fnum(metric(text, "READ", "99thPercentileLatency(us)"))
    p999 = fnum(metric(text, "READ", "99.9thPercentileLatency(us)")) or parse_status_line_p999(text)
    return {
        "throughput": fnum(metric(text, "OVERALL", "Throughput(ops/sec)")),
        "runtime_ms": fnum(metric(text, "OVERALL", "RunTime(ms)")),
        "read_ops": fnum(metric(text, "READ", "Operations")),
        "avg": fnum(metric(text, "READ", "AverageLatency(us)")),
        "p95": fnum(metric(text, "READ", "95thPercentileLatency(us)")),
        "p99": p99,
        "p999": max(p999, p99),
        "errors": count_errors(text),
        "timeouts": len(re.findall(r"timeout", text, re.I)),
    }


def parse_ycsb(run_dir):
    paths = sorted((run_dir / "metrics" / "ycsb-raw").glob("client-*.log"))
    clients = [parse_client(path) for path in paths]
    ops = sum(c["read_ops"] for c in clients)
    return {
        "client_logs": len(clients),
        "throughput": sum(c["throughput"] for c in clients),
        "runtime_ms_max": max([c["runtime_ms"] for c in clients], default=0.0),
        "read_ops": ops,
        "avg_latency": sum(c["avg"] * c["read_ops"] for c in clients) / ops if ops else 0.0,
        "p95_latency": max([c["p95"] for c in clients], default=0.0),
        "p99_latency": max([c["p99"] for c in clients], default=0.0),
        "p999_latency": max([c["p999"] for c in clients], default=0.0),
        "error_count": sum(c["errors"] for c in clients),
        "timeout_count": sum(c["timeouts"] for c in clients),
    }


def read_workload(run_dir):
    data = {}
    for line in read_text(run_dir / "meta" / "workload.env").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            data[key] = value
    return data


def discover_runs(exp_dir):
    runs = []
    for raw_dir in sorted(exp_dir.glob("*/r*/metrics/ycsb-raw")):
        run_dir = raw_dir.parents[1]
        runs.append(run_dir)
    for raw_dir in sorted(exp_dir.glob("*/metrics/ycsb-raw")):
        run_dir = raw_dir.parents[1]
        if run_dir not in runs:
            runs.append(run_dir)
    return runs


def parse_cpu(run_dir):
    path = run_dir / "metrics" / "cpu-node-samples.csv"
    if not path.exists():
        return {}
    with path.open(newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    if len(rows) > 5:
        rows = rows[5:]
    fields = rows[0].keys() if rows else []
    node_fields = sorted([field for field in fields if re.match(r"node[0-9]+_busy_pct$", field)])
    result = {"cpu_samples": len(rows)}
    for field in node_fields:
        base = field[:-4] if field.endswith("_pct") else field
        vals = [fnum(row.get(field)) for row in rows]
        result[f"{base}_avg"] = statistics.mean(vals) if vals else 0.0
        result[f"{base}_max"] = max(vals) if vals else 0.0
    for group_name, nodes in {
        "nodes01": (0, 1),
        "nodes012": (0, 1, 2),
        "nodes0123": (0, 1, 2, 3),
    }.items():
        vals = []
        for row in rows:
            present = [fnum(row.get(f"node{node}_busy_pct")) for node in nodes if f"node{node}_busy_pct" in row]
            if present:
                vals.append(statistics.mean(present))
        result[f"{group_name}_busy_avg"] = statistics.mean(vals) if vals else 0.0
        result[f"{group_name}_busy_max"] = max(vals) if vals else 0.0
        result[f"{group_name}_saturated_85"] = "yes" if sustained(vals, 85.0, 60) else "no"
    return result


def sustained(vals, threshold, count):
    streak = 0
    for val in vals:
        if val >= threshold:
            streak += 1
            if streak >= count:
                return True
        else:
            streak = 0
    return False


def stdev(vals):
    return statistics.stdev(vals) if len(vals) >= 2 else 0.0


def write_csv(path, rows, fields):
    with Path(path).open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            out = {}
            for field in fields:
                value = row.get(field, "")
                out[field] = f"{value:.6f}" if isinstance(value, float) and math.isfinite(value) else value
            writer.writerow(out)


def aggregate(rows):
    grouped = defaultdict(list)
    for row in rows:
        grouped[row["label"]].append(row)
    out = []
    for label, items in sorted(grouped.items()):
        tputs = [fnum(item.get("throughput")) for item in items]
        avgs = [fnum(item.get("avg_latency")) for item in items]
        p95s = [fnum(item.get("p95_latency")) for item in items]
        p99s = [fnum(item.get("p99_latency")) for item in items]
        out.append(
            {
                "label": label,
                "rounds": len(items),
                "throughput_mean": statistics.mean(tputs) if tputs else 0.0,
                "throughput_stdev": stdev(tputs),
                "throughput_min": min(tputs) if tputs else 0.0,
                "throughput_max": max(tputs) if tputs else 0.0,
                "avg_latency_mean": statistics.mean(avgs) if avgs else 0.0,
                "p95_latency_mean": statistics.mean(p95s) if p95s else 0.0,
                "p99_latency_mean": statistics.mean(p99s) if p99s else 0.0,
            }
        )
    return out


def discover_server_runs(exp_dir):
    server_root = exp_dir / "server"
    runs = []
    if not server_root.exists():
        return runs
    for metrics_dir in sorted(server_root.glob("*/r*/metrics")):
        runs.append(metrics_dir.parents[1])
    return runs


def build_server_cpu_rows(exp_dir):
    rows = []
    for run_dir in discover_server_runs(exp_dir):
        workload = read_workload(run_dir)
        label = workload.get("label") or run_dir.parent.name
        round_id = run_dir.name if run_dir.name.startswith("r") else workload.get("round", "")
        row = {
            "label": label,
            "round": round_id,
            "total_threads": workload.get("total_threads", ""),
            "host_role": "server",
        }
        row.update(parse_cpu(run_dir))
        rows.append(row)
    return rows


def md_table(rows, fields, headers):
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(fields)) + " |"]
    for row in rows:
        vals = []
        for field in fields:
            value = row.get(field, "")
            vals.append(f"{value:.2f}" if isinstance(value, float) else str(value))
        lines.append("| " + " | ".join(vals) + " |")
    return "\n".join(lines)


def build_report(exp_dir, rows, agg_rows, server_cpu_rows):
    report = [
        "# YCSB JDBC Benchmark Report",
        "",
        "## Summary",
        "",
        f"- Experiment directory: `{exp_dir}`",
        f"- Runs discovered: `{len(rows)}`",
        "",
        "## Per-Run YCSB Results",
        "",
        md_table(
            rows,
            ["label", "round", "total_threads", "client_logs", "throughput", "avg_latency", "p95_latency", "p99_latency", "p999_latency", "error_count"],
            ["label", "round", "threads", "clients", "throughput", "avg us", "p95 us", "p99 us", "p999 us", "errors"],
        ),
        "",
        "## Aggregated By Label",
        "",
        md_table(
            agg_rows,
            ["label", "rounds", "throughput_mean", "throughput_stdev", "avg_latency_mean", "p95_latency_mean", "p99_latency_mean"],
            ["label", "rounds", "throughput mean", "throughput stdev", "avg us mean", "p95 us mean", "p99 us mean"],
        ),
        "",
        "## CPU Node Busy",
        "",
        md_table(
            rows,
            ["label", "round", "node0_busy_avg", "node1_busy_avg", "node2_busy_avg", "node3_busy_avg", "nodes012_busy_avg", "nodes012_busy_max", "nodes012_saturated_85"],
            ["label", "round", "node0 avg", "node1 avg", "node2 avg", "node3 avg", "nodes0-2 avg", "nodes0-2 max", ">=85% 60s"],
        ),
        "",
        "## Server CPU Node Busy",
        "",
        md_table(
            server_cpu_rows,
            ["label", "round", "node0_busy_avg", "node1_busy_avg", "node2_busy_avg", "node3_busy_avg", "nodes012_busy_avg", "nodes012_busy_max", "nodes012_saturated_85"],
            ["label", "round", "node0 avg", "node1 avg", "node2 avg", "node3 avg", "nodes0-2 avg", "nodes0-2 max", ">=85% 60s"],
        ) if server_cpu_rows else "No separate server CPU samples were found.",
        "",
        "## Notes",
        "",
        "- Throughput is summed across client logs.",
        "- Average latency is weighted by READ operation count.",
        "- P95/P99/P999 use the conservative max across client logs.",
        "- Error and timeout counts are parsed from raw YCSB logs and should be checked against raw logs for failure diagnosis.",
    ]
    return "\n".join(report) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--experiment-dir", required=True)
    args = parser.parse_args()
    exp_dir = Path(args.experiment_dir).resolve()
    runs = discover_runs(exp_dir)

    rows = []
    for run_dir in runs:
        workload = read_workload(run_dir)
        label = workload.get("label") or run_dir.parent.name
        round_id = run_dir.name if run_dir.name.startswith("r") else workload.get("round", "")
        row = {
            "label": label,
            "round": round_id,
            "clients": workload.get("clients", ""),
            "threads_per_client": workload.get("threads_per_client", ""),
            "total_threads": workload.get("total_threads", ""),
            "ops_per_client": workload.get("ops_per_client", ""),
        }
        row.update(parse_ycsb(run_dir))
        row.update(parse_cpu(run_dir))
        rows.append(row)

    summary_fields = [
        "label", "round", "clients", "threads_per_client", "total_threads", "ops_per_client",
        "client_logs", "throughput", "runtime_ms_max", "read_ops", "avg_latency",
        "p95_latency", "p99_latency", "p999_latency", "error_count", "timeout_count",
    ]
    write_csv(exp_dir / "summary.csv", rows, summary_fields)

    agg_rows = aggregate(rows)
    write_csv(
        exp_dir / "summary-by-label.csv",
        agg_rows,
        [
            "label", "rounds", "throughput_mean", "throughput_stdev", "throughput_min",
            "throughput_max", "avg_latency_mean", "p95_latency_mean", "p99_latency_mean",
        ],
    )

    cpu_fields = [
        "label", "round", "total_threads", "cpu_samples",
        "node0_busy_avg", "node1_busy_avg", "node2_busy_avg", "node3_busy_avg",
        "nodes01_busy_avg", "nodes01_busy_max", "nodes01_saturated_85",
        "nodes012_busy_avg", "nodes012_busy_max", "nodes012_saturated_85",
        "nodes0123_busy_avg", "nodes0123_busy_max", "nodes0123_saturated_85",
    ]
    write_csv(exp_dir / "cpu-node-summary.csv", rows, cpu_fields)
    server_cpu_rows = build_server_cpu_rows(exp_dir)
    write_csv(
        exp_dir / "server-cpu-node-summary.csv",
        server_cpu_rows,
        ["label", "round", "host_role", "total_threads", "cpu_samples",
         "node0_busy_avg", "node1_busy_avg", "node2_busy_avg", "node3_busy_avg",
         "nodes01_busy_avg", "nodes01_busy_max", "nodes01_saturated_85",
         "nodes012_busy_avg", "nodes012_busy_max", "nodes012_saturated_85",
         "nodes0123_busy_avg", "nodes0123_busy_max", "nodes0123_saturated_85"],
    )
    (exp_dir / "report.md").write_text(build_report(exp_dir, rows, agg_rows, server_cpu_rows), encoding="utf-8")


if __name__ == "__main__":
    main()
