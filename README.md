# ycsb-bench-all-database

`ycsb-bench-all-database` 是面向 Doris 和 ClickHouse 的 YCSB 压测工具。当前主线优先服务 Doris：固定沉淀 `kunpen183` / `ubuntu197` 上的单机、双机、cgroup v2 cpuset 隔离和用户态线程聚集实验流程。ClickHouse 目前保留同样的配置骨架，等连接参数和启停方式明确后再补齐可直接运行的示例。

工具仍然通过 JDBC/YCSB 执行 workload，但项目目标不再是“任意数据库通用压测框架”，而是把 Doris/ClickHouse 的可复现实验流程做稳。

## Quick Start

```bash
cd /data/sched-ext-study/ycsb-bench-all-database

./bin/yba preflight --config examples/doris/singlehost-baseline.env
./bin/yba run --config examples/doris/singlehost-baseline.env
./bin/yba summarize --experiment-dir experiments/<run>
./bin/yba cleanup --config examples/doris/singlehost-baseline.env
```

命令行环境变量会覆盖配置文件中的值：

```bash
MATRIX='t80:5:16' OPERATIONCOUNT_PER_CLIENT=50000 \
  ./bin/yba run --config examples/doris/dualhost-baseline.env
```

`MATRIX` 格式为 `label:client_processes:threads_per_client`。例如 `t80:5:16` 表示 5 个 YCSB JVM，每个 16 线程，总 80 client 线程。

## Doris Scenarios

四个基础场景已经固化为 Doris 示例：

| 场景 | 配置 | 说明 |
| --- | --- | --- |
| 单机 baseline | `examples/doris/singlehost-baseline.env` | Doris 和 YCSB 同机，无 cgroup 限制 |
| 双机 baseline | `examples/doris/dualhost-baseline.env` | Doris 在 `kunpen183`，YCSB 在 `ubuntu197` |
| 单机 cgroup | `examples/doris/singlehost-cgroup2.env` | Doris/YCSB 同在 `kunpen183`，用 cpuset 分 NUMA node |
| 双机 cgroup | `examples/doris/dualhost-cgroup2.env` | server/client 在各自主机按 cgroup 配置限制 |

另有高级示例：

```bash
./bin/yba run --config examples/doris/thread-cluster.env
```

该示例使用 `taskset -pc` 对 Doris BE 线程名做用户态线程聚集，不涉及内核调度器。规则格式：

```bash
THREAD_CLUSTER_RULES='query:brpc_light|Pipe_normal|Scan_normal:32-63 background:brpc_heavy|Flush|Task:0-31'
```

每条规则为 `name:comm_regex:cpu_list`。当前只绑定每轮开始时已经存在的 TID；Doris 后续动态创建的新线程需要重新绑定或后续扩展周期性 binder。

## Doris Startup

Doris 默认通过自带脚本启停，不再依赖旧实验目录：

```bash
DORIS_HOME=/home/xhc/doris/apache-doris-2.1.2-bin-arm64
DORIS_START_FE=$DORIS_HOME/fe/bin/start_fe.sh
DORIS_START_BE=$DORIS_HOME/be/bin/start_be.sh
DORIS_STOP_FE=$DORIS_HOME/fe/bin/stop_fe.sh
DORIS_STOP_BE=$DORIS_HOME/be/bin/stop_be.sh
DORIS_READY_CMD="mysql -h127.0.0.1 -P9030 -uroot -e 'select 1'"
SERVER_READY_TIMEOUT=120
```

如果你的机器 Doris 安装路径不同，通常只需要改 `DORIS_HOME`。如需完全自定义启停流程，可以设置：

```bash
SERVER_SETUP_CMD='...'
SERVER_READY_CMD='...'
SERVER_CLEANUP_CMD='...'
```

显式 hook 会覆盖 Doris 默认启停逻辑。

`SERVER_READY_CMD` 会循环重试，默认最多等待 120 秒。超时后 yba 会中止本轮运行，不会继续启动 YCSB。

默认 Doris PID 发现同时包含 BE 和 FE：

```bash
SERVER_PID_COMMAND='pgrep -x doris_be; pgrep -f "org[.]apache[.]doris[.]DorisFE"'
```

## Swap Check

Doris BE 启动时要求关闭 swap，否则可能报：

```text
Please disable swap memory before installation.
```

yba 在 Doris preflight/start 前会检查 swap：

```bash
DORIS_SWAP_CHECK=1
DORIS_SWAPOFF_WITH_SUDO=0
```

如果 swap 已开启且未允许 yba 使用 sudo，工具会失败并提示手动执行：

```bash
sudo swapoff -a
```

如果允许 yba 自动执行：

```bash
DORIS_SWAPOFF_WITH_SUDO=1
SUDO_ASKPASS=/path/to/askpass.sh   # 可选
```

`swapoff -a` 只影响当前启动周期；yba 不会修改 `/etc/fstab`，因此重启后可能需要重新关闭 swap。

## cgroup v2

关闭 cgroup：

```bash
ENABLE_CGROUP=0
```

这会完全跳过 cgroup 检查、配置和进程迁移。

启用 cgroup v2 cpuset：

```bash
ENABLE_CGROUP=1
CGROUP_ROOT=/run/cgroup2/doris-bench
SERVER_CGROUP=/run/cgroup2/doris-bench/doris
CLIENT_CGROUP=/run/cgroup2/doris-bench/ycsb
SERVER_CPUSET_EXPECT=0-63
SERVER_MEMS_EXPECT=0-1
CLIENT_CPUSET_EXPECT=64-127
CLIENT_MEMS_EXPECT=2-3
```

如果 root 已经挂载并委托 `/run/cgroup2/doris-bench` 给当前用户，可以让 yba 写 `cpuset.cpus` 和 `cpuset.mems`：

```bash
CGROUP_AUTO_CONFIG=1
CGROUP_WRITE_WITH_SUDO=0
```

进程迁移写入的是 `cgroup.procs`，权限可能和 cpuset 文件不同：

```bash
CGROUP_PROCS_WRITE_WITH_SUDO=0
```

如果迁移时报 `cannot move pid ... cgroup.procs`，再单独改为：

```bash
CGROUP_PROCS_WRITE_WITH_SUDO=1
```

单机模式会同时检查 server/client cgroup；双机模式会在 server 主机检查 server cgroup，在 client 主机检查 client cgroup。

## ClickHouse

ClickHouse 本轮只提供模板：

```text
examples/clickhouse/singlehost-baseline.env.example
examples/clickhouse/dualhost-baseline.env.example
```

使用前需要补齐：

```bash
DB_TYPE=clickhouse
JDBC_URL='jdbc:clickhouse://<host>:8123/ycsb'
JDBC_DRIVER=com.clickhouse.jdbc.ClickHouseDriver
JDBC_JAR=/path/to/clickhouse-jdbc.jar
SERVER_SETUP_CMD='...'
SERVER_READY_CMD='...'
SERVER_CLEANUP_CMD='...'
SERVER_PID_COMMAND='pgrep -x clickhouse-server'
```

如果没有设置 ClickHouse 的启停 hook，preflight 会直接失败并提示补齐。

## Output

每次运行会在 `LOCAL_RESULTS_ROOT` 下创建带时间戳的实验目录：

```text
experiments/<timestamp>-<experiment-name>/
  <label>/r1/
    meta/
    metrics/
      ycsb-raw/client-*.log
      cpu-node-samples.csv
      vmstat.log
      numastat-before.txt
      numastat-after.txt
      ps-top.log
    cgroup/
    thread-cluster/
    server/
  server/
  summary.csv
  summary-by-label.csv
  cpu-node-summary.csv
  server-cpu-node-summary.csv
  report.md
```

汇总规则：

- throughput：多个 YCSB client 日志求和。
- average latency：按 READ operation count 加权平均。
- P95/P99/P999：取多个 client 中的保守最大值。
- error/timeout：从 YCSB 原始日志解析。
- NUMA node CPU busy：读取 `/proc/stat` 并按 `lscpu -e=CPU,NODE,ONLINE` 聚合。

## Verification

```bash
bash -n bin/yba lib/*.sh
python3 -m py_compile tools/sample-node-cpu.py tools/summarize-ycsb.py
python3 tests/test_summarize_ycsb.py
```

## Operational Notes

- `kunpen183` / `ubuntu197` 默认通过 SSH alias 访问；正式服务器可改成 IP。
- 远端机器只作为执行环境，关键 CSV 和报告会同步回本地 `experiments/`。
- 清理逻辑依赖配置 hook 和明确 PID，避免使用 `pkill -f`。
- 用户态线程聚集依赖 Linux `comm`，线程名可能被截断到 15 字符。
- 单 NUMA node 聚集在中低负载可能有效，高负载下可能变成 CPU 争用瓶颈。
