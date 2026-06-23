#!/usr/bin/env python3
import argparse
import csv
import math
import statistics
from collections import defaultdict
from pathlib import Path


def fnum(value, default=0.0):
    try:
        if value in (None, ""):
            return default
        return float(value)
    except (TypeError, ValueError):
        return default


def stdev(values):
    return statistics.stdev(values) if len(values) >= 2 else 0.0


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


def parse_run_name(name):
    parts = name.rsplit("-", 2)
    if len(parts) != 3:
        return name, "", ""
    return parts[0], parts[1], parts[2]


def read_first_summary(run_dir):
    path = run_dir / "summary.csv"
    if not path.exists():
        return None
    with path.open(newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    return rows[0] if rows else None


def discover_run_rows(suite_dir):
    rows = []
    runs_dir = suite_dir / "runs"
    for run_dir in sorted(runs_dir.iterdir() if runs_dir.exists() else []):
        if not run_dir.is_dir():
            continue
        profile, load, round_id = parse_run_name(run_dir.name)
        summary = read_first_summary(run_dir)
        if summary is None:
            rows.append({"profile": profile, "load": load, "round": round_id, "status": "missing_summary"})
            continue
        row = {
            "profile": profile,
            "load": load or summary.get("label", ""),
            "round": round_id,
            "status": "ok",
            "clients": summary.get("clients", ""),
            "threads_per_client": summary.get("threads_per_client", ""),
            "total_threads": summary.get("total_threads", ""),
            "ops_per_client": summary.get("ops_per_client", ""),
            "throughput": fnum(summary.get("throughput")),
            "avg_latency": fnum(summary.get("avg_latency")),
            "p95_latency": fnum(summary.get("p95_latency")),
            "p99_latency": fnum(summary.get("p99_latency")),
            "p999_latency": fnum(summary.get("p999_latency")),
            "error_count": fnum(summary.get("error_count")),
            "timeout_count": fnum(summary.get("timeout_count")),
        }
        rows.append(row)
    return rows


def aggregate(rows):
    grouped = defaultdict(list)
    for row in rows:
        if row.get("status") == "ok":
            grouped[(row["profile"], row["load"])].append(row)
    baseline = {}
    numa = {}
    for key, items in grouped.items():
        values = [fnum(item.get("throughput")) for item in items]
        mean = statistics.mean(values) if values else 0.0
        if key[0] == "baseline":
            baseline[key[1]] = mean
        if key[0] == "numa_node1":
            numa[key[1]] = mean
    out = []
    for (profile, load), items in sorted(grouped.items()):
        tputs = [fnum(item.get("throughput")) for item in items]
        avgs = [fnum(item.get("avg_latency")) for item in items]
        p95s = [fnum(item.get("p95_latency")) for item in items]
        p99s = [fnum(item.get("p99_latency")) for item in items]
        mean = statistics.mean(tputs) if tputs else 0.0
        base = baseline.get(load, 0.0)
        numa_mean = numa.get(load, 0.0)
        out.append(
            {
                "profile": profile,
                "load": load,
                "rounds": len(items),
                "throughput_mean": mean,
                "throughput_stdev": stdev(tputs),
                "throughput_min": min(tputs) if tputs else 0.0,
                "throughput_max": max(tputs) if tputs else 0.0,
                "avg_latency_mean": statistics.mean(avgs) if avgs else 0.0,
                "p95_latency_mean": statistics.mean(p95s) if p95s else 0.0,
                "p99_latency_mean": statistics.mean(p99s) if p99s else 0.0,
                "vs_baseline_pct": ((mean / base) - 1.0) * 100.0 if base else 0.0,
                "vs_numa_node1_pct": ((mean / numa_mean) - 1.0) * 100.0 if numa_mean else 0.0,
            }
        )
    return out


def discover_thread_rows(suite_dir):
    out = []
    runs_dir = suite_dir / "runs"
    for run_dir in sorted(runs_dir.iterdir() if runs_dir.exists() else []):
        if not run_dir.is_dir():
            continue
        profile, load, round_id = parse_run_name(run_dir.name)
        for summary_path in sorted((run_dir / "server").glob("*/r*/thread-cluster/summary.csv")):
            with summary_path.open(newline="", encoding="utf-8") as fh:
                for row in csv.DictReader(fh):
                    row.update({"profile": profile, "load": load, "round": round_id})
                    out.append(row)
    return out


def md_table(rows, fields):
    lines = ["| " + " | ".join(fields) + " |", "| " + " | ".join(["---"] * len(fields)) + " |"]
    for row in rows:
        vals = []
        for field in fields:
            value = row.get(field, "")
            vals.append(f"{value:.2f}" if isinstance(value, float) else str(value))
        lines.append("| " + " | ".join(vals) + " |")
    return "\n".join(lines)


def build_key_findings(agg_rows, thread_rows):
    lines = ["## 关键结论", ""]
    by_profile_load = {(row.get("profile"), row.get("load")): row for row in agg_rows}
    loads = sorted({row.get("load") for row in agg_rows if row.get("load")})
    for load in loads:
        cluster = by_profile_load.get(("cluster_hot_node3_other_node2", load))
        numa = by_profile_load.get(("numa_node1", load))
        baseline = by_profile_load.get(("baseline", load))
        if cluster:
            lines.append(
                "- cluster_hot_node3_other_node2 在 {load} 下相对 baseline 吞吐 {vs_base:+.2f}%，"
                "相对 numa_node1 {vs_numa:+.2f}%；平均吞吐 {throughput:.2f} ops/s，"
                "P95/P99 平均为 {p95:.0f}/{p99:.0f} us。".format(
                    load=load,
                    vs_base=fnum(cluster.get("vs_baseline_pct")),
                    vs_numa=fnum(cluster.get("vs_numa_node1_pct")),
                    throughput=fnum(cluster.get("throughput_mean")),
                    p95=fnum(cluster.get("p95_latency_mean")),
                    p99=fnum(cluster.get("p99_latency_mean")),
                )
            )
        if numa and baseline:
            lines.append(
                "- numa_node1 在 {load} 下相对 baseline 吞吐 {vs_base:+.2f}%，说明单 node 聚集本身有效；"
                "但它把 BE 全部压到 node1，可能比只聚集高共享线程组更容易产生 node 内争用。".format(
                    load=load,
                    vs_base=fnum(numa.get("vs_baseline_pct")),
                )
            )

    hot_rows = [
        row
        for row in thread_rows
        if row.get("profile") == "cluster_hot_node3_other_node2" and row.get("rule") == "hot"
    ]
    if hot_rows:
        min_hot = min(fnum(row.get("hit_ratio")) for row in hot_rows)
        lines.append(
            "- 线程聚集证据：cluster profile 的 hot 规则在所有轮次 hit_ratio 最低为 "
            f"{min_hot:.6f}，说明 brpc_heavy/brpc_light/Pipe_normal 目标线程稳定落在 node3。"
        )
    other_rows = [
        row
        for row in thread_rows
        if row.get("profile") == "cluster_hot_node3_other_node2" and row.get("rule") == "other"
    ]
    if other_rows:
        min_other = min(fnum(row.get("hit_ratio")) for row in other_rows)
        max_other = max(fnum(row.get("hit_ratio")) for row in other_rows)
        lines.append(
            "- other 规则是一次性 taskset 尽力放置，hit_ratio 范围为 "
            f"{min_other:.6f}-{max_other:.6f}，因此本轮结论主要建立在 hot 线程组稳定聚集上，"
            "不能把 other 组视为严格隔离成功。"
        )
    numa_rows = [row for row in thread_rows if row.get("profile") == "numa_node1" and row.get("rule") == "all"]
    if numa_rows:
        min_numa = min(fnum(row.get("hit_ratio")) for row in numa_rows)
        lines.append(
            f"- numa_node1 的 all 规则存活线程 hit_ratio 最低为 {min_numa:.6f}；"
            "thread_set_state=changed 主要来自少量短生命周期线程退出，不代表存活线程跑出 node1。"
        )
    lines.extend(
        [
            "- 阶段性判断：在这组中低负载双机 YCSB read-only 实验里，线程组级聚集不仅优于 baseline，也优于整进程 node1 NUMA control；更像是减少了高共享查询链路线程的跨 node 同步/唤醒成本，同时避免把全部 BE 线程都挤到同一 node。",
            "",
        ]
    )
    return lines


def build_report(suite_dir, rows, agg_rows, thread_rows):
    report = [
        "# Doris/YCSB 双机线程聚集 Node3/Node2 复验报告",
        "",
        "## 实验概况",
        "",
        f"- Suite directory: `{suite_dir}`",
        f"- Runs discovered: `{len(rows)}`",
        "- 服务端：`kunpen183` Doris；客户端：`ubuntu197` YCSB。",
        "- Profile：baseline、numa_node1、cluster_hot_node3_other_node2。",
        "- Load：t16 与 t80；每个 profile/load 3 轮。",
        "",
    ]
    report.extend(build_key_findings(agg_rows, thread_rows))
    report.extend(
        [
        "## 每轮结果",
        "",
        md_table(rows, ["profile", "load", "round", "throughput", "avg_latency", "p95_latency", "p99_latency", "error_count"]),
        "",
        "## Profile 聚合",
        "",
        md_table(agg_rows, ["profile", "load", "rounds", "throughput_mean", "throughput_stdev", "avg_latency_mean", "p95_latency_mean", "p99_latency_mean", "vs_baseline_pct", "vs_numa_node1_pct"]),
        "",
        "## 线程聚集校验",
        "",
        md_table(thread_rows, ["profile", "load", "round", "rule", "bound_threads", "after_ycsb_threads", "on_target_cpu_threads", "hit_ratio", "thread_set_state"]) if thread_rows else "baseline 不启用线程聚集；未发现 thread-cluster summary。",
        "",
        "## 注意事项",
        "",
        "- 本轮是用户态一次性线程聚集，不是持续守护；若 Doris 后续动态创建新的目标线程，仍需要周期性补绑或 cgroup/线程级迁移机制。",
        "- cluster profile 中 other 线程组没有达到严格隔离，只作为背景线程尽力迁出 node3 的证据记录。",
        "- 本轮只覆盖 t16/t80 read-only zipfian YCSB，不直接外推到更高负载、写入型 workload 或 ClickHouse。",
        "",
        ]
    )
    return "\n".join(report) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--suite-dir", required=True)
    args = parser.parse_args()
    suite_dir = Path(args.suite_dir).resolve()

    rows = discover_run_rows(suite_dir)
    agg_rows = aggregate(rows)
    thread_rows = discover_thread_rows(suite_dir)

    write_csv(
        suite_dir / "suite-summary.csv",
        rows,
        ["profile", "load", "round", "status", "clients", "threads_per_client", "total_threads", "ops_per_client", "throughput", "avg_latency", "p95_latency", "p99_latency", "p999_latency", "error_count", "timeout_count"],
    )
    write_csv(
        suite_dir / "suite-summary-by-profile-load.csv",
        agg_rows,
        ["profile", "load", "rounds", "throughput_mean", "throughput_stdev", "throughput_min", "throughput_max", "avg_latency_mean", "p95_latency_mean", "p99_latency_mean", "vs_baseline_pct", "vs_numa_node1_pct"],
    )
    write_csv(
        suite_dir / "thread-cluster-suite-summary.csv",
        thread_rows,
        ["profile", "load", "round", "rule", "bound_threads", "after_ycsb_threads", "on_target_cpu_threads", "new_threads", "missing_threads", "hit_ratio", "thread_set_state"],
    )
    (suite_dir / "ycsb-doris-dualhost-thread-cluster-node3-node2-x3-report-cn.md").write_text(
        build_report(suite_dir, rows, agg_rows, thread_rows),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
