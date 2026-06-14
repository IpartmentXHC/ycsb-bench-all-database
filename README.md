# ycsb-bench-all-database

中文 | [English](#english)

## 中文

`ycsb-bench-all-database` 是一个 Bash CLI，用于可复现地运行 JDBC/YCSB 数据库压测。它把 Doris/YCSB 实验中沉淀出的流程固化为配置驱动工具，包括单机测试、双机测试、cgroup v2 cpuset 隔离、用户态线程聚集、多 YCSB client 并发、NUMA node CPU 采样、原始日志归档，以及 CSV/Markdown 汇总报告。

第一版刻意保持轻依赖：

- 配置文件使用 shell env 格式。
- 数据库接口抽象为通用 JDBC。
- Doris 通过示例配置和 `SERVER_SETUP_CMD` / `SERVER_CLEANUP_CMD` hook 支持。
- cgroup v2 只负责检查、迁移和验证；root 级挂载、授权和子树创建由用户提前完成。

### 目录结构

```text
ycsb-bench-all-database/
  bin/yba
  lib/
  tools/
  examples/
  experiments/
```

### CLI

```bash
./bin/yba preflight --config examples/singlehost-cgroup2.env
./bin/yba run --config examples/singlehost-cgroup2.env
./bin/yba summarize --experiment-dir experiments/<run>
./bin/yba cleanup --config examples/singlehost-cgroup2.env
```

命令行环境变量会覆盖配置文件中的值：

```bash
MATRIX="t1:1:1" OPERATIONCOUNT_PER_CLIENT=1000 \
  ./bin/yba run --config examples/dualhost-doris.env
```

### 运行模式

#### 单机模式

`MODE=singlehost` 会在 `SERVER_HOST` 上执行服务端 hook，并在同一台机器上启动 YCSB client。该模式适合 cgroup v2 资源隔离场景，例如 Doris 使用 NUMA node0-2，YCSB 使用 node3。

```bash
./bin/yba run --config examples/singlehost-cgroup2.env
```

#### 双机模式

`MODE=dualhost` 会在 `SERVER_HOST` 上执行服务端 hook，在 `CLIENT_HOST` 上运行 YCSB client。

```bash
./bin/yba run --config examples/dualhost-doris.env
```

#### 线程聚集

线程聚集在服务端 ready 之后执行，通过线程名正则匹配 TID，再用 `taskset -pc` 绑定 CPU：

```bash
THREAD_CLUSTER_RULES='query:brpc_light|Pipe_normal|Scan_normal:32-63 background:brpc_heavy|Flush|Task:0-31'
```

每条规则格式为：

```text
name:comm_regex:cpu_list
```

第一版只会对每轮开始时已经存在的 TID 执行一次绑定。如果程序后续动态创建新线程，需要重新执行绑定，或后续扩展为周期性 binder。

### 核心配置

```bash
MODE=singlehost|dualhost
SERVER_HOST=kunpen183
CLIENT_HOST=ubuntu197
REMOTE_ROOT=/home/xhc/ExperScript/ycsb-bench-all-database
LOCAL_RESULTS_ROOT=/data/sched-ext-study/ycsb-bench-all-database/experiments

SSH_OPTS='-F ~/.ssh/config'
SERVER_SSH_OPTS='-p 22183'
CLIENT_SSH_OPTS='-p 22197'

YCSB_HOME=/home/xhc/ycsb-jdbc-binding-0.17.0
PYTHON2_BIN=python2
JDBC_URL='jdbc:mysql://127.0.0.1:9030/ycsb?useSSL=false'
JDBC_USER=root
JDBC_PASSWORD=
JDBC_DRIVER=com.mysql.cj.jdbc.Driver
JDBC_JAR=/home/xhc/ycsb-jdbc-binding-0.17.0/lib/mysql-connector-java-8.0.28.jar
TABLE=usertable

WORKLOAD_FILE=
GENERATE_WORKLOAD=1
RECORDCOUNT=1000000
OPERATIONCOUNT_PER_CLIENT=50000
REQUEST_DISTRIBUTION=zipfian
READ_PROPORTION=1
UPDATE_PROPORTION=0
MATRIX='t80:5:16 t128:8:16'
ROUNDS=1

ENABLE_CGROUP=0
SERVER_CGROUP=/run/cgroup2/ycsb-bench/server
CLIENT_CGROUP=/run/cgroup2/ycsb-bench/client
SERVER_CPUSET_EXPECT=0-95
SERVER_MEMS_EXPECT=0-2
CLIENT_CPUSET_EXPECT=96-127
CLIENT_MEMS_EXPECT=3

ENABLE_THREAD_CLUSTER=0
THREAD_CLUSTER_RULES='query:brpc_light|Pipe_normal|Scan_normal:32-63'

SERVER_SETUP_CMD=
SERVER_READY_CMD="mysql -h127.0.0.1 -P9030 -uroot -e 'select 1'"
SERVER_CLEANUP_CMD=
SERVER_PID_COMMAND='pgrep -x doris_be'
```

`MATRIX` 的每个条目格式为：

```text
label:client_processes:threads_per_client
```

例如 `t80:5:16` 表示启动 5 个 YCSB 进程，每个进程 16 个线程，总共 80 个 client 线程。

### cgroup v2 要求

工具不会以 root 身份挂载 cgroup v2，也不会创建或授权 cgroup 子树。请提前准备好子树，然后配置：

```bash
ENABLE_CGROUP=1
SERVER_CGROUP=/run/cgroup2/doris-bench/doris
CLIENT_CGROUP=/run/cgroup2/doris-bench/ycsb
SERVER_CPUSET_EXPECT=0-95
SERVER_MEMS_EXPECT=0-2
CLIENT_CPUSET_EXPECT=96-127
CLIENT_MEMS_EXPECT=3
```

`preflight` 会检查 effective CPU 和 memory node 列表。运行过程中，服务端 PID 和 YCSB client shell 会被迁移到对应 cgroup，并保存 `/proc/<pid>/status` 快照。

如果写入 cgroup 需要 sudo：

```bash
CGROUP_WRITE_WITH_SUDO=1
SUDO_ASKPASS=/path/to/askpass.sh
```

### SSH 与跳板机

默认情况下，工具直接使用配置中的 SSH alias：

```bash
SERVER_HOST=kunpen183
CLIENT_HOST=ubuntu197
```

如果环境中存在跳板机、端口转发、独立 SSH config 或不同 key，可以显式配置：

```bash
SSH_BIN=ssh
SCP_BIN=scp
RSYNC_BIN=rsync
SSH_OPTS='-F /path/to/ssh_config -o BatchMode=yes'
SERVER_SSH_OPTS='-J jump-host -i ~/.ssh/server_key'
CLIENT_SSH_OPTS='-p 22197 -i ~/.ssh/client_key'
```

`SERVER_SSH_OPTS` 和 `CLIENT_SSH_OPTS` 会根据目标 host 是否等于 `SERVER_HOST` 或 `CLIENT_HOST` 自动追加到 `SSH_OPTS` 后面。`scp` 默认复用对应 SSH 参数；如需特殊配置，可使用 `SERVER_SCP_OPTS` 或 `CLIENT_SCP_OPTS`。

`rsync` 默认通过同一套 SSH 命令作为 `-e` 参数。只有在需要自定义 remote shell 时才覆盖：

```bash
SERVER_RSYNC_RSH='ssh -F /path/to/ssh_config -J jump-host'
CLIENT_RSYNC_RSH='ssh -F /path/to/ssh_config -p 22197'
```

### 输出

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
    doris/
  summary.csv
  summary-by-label.csv
  cpu-node-summary.csv
  report.md
```

汇总规则：

- throughput 对多个 client 日志求和。
- average latency 按 READ operation count 加权平均。
- P95/P99/P999 取多个 client 中的保守最大值。
- error 和 timeout 从 YCSB 原始日志中解析。
- NUMA node CPU busy 从 `/proc/stat` 采样，并按 `lscpu -e=CPU,NODE,ONLINE` 分组。

### 安全说明

- 脚本避免使用 `pkill -f`；清理应使用配置的 hook 或明确的进程名/PID。
- 远端主机通过 SSH alias 访问，例如 `kunpen183` 和 `ubuntu197`。
- 远端主机只作为执行环境；报告和关键 CSV 会同步回本地实验目录。
- 线程名匹配依赖 Linux `comm`，通常会被截断到 15 个字符；建议使用前缀或较宽松的正则。
- 单 NUMA node 聚集在中低负载可能提升局部性，但在高负载下可能变成瓶颈。

### 本地验证

```bash
bash -n bin/yba lib/*.sh
python3 -m py_compile tools/sample-node-cpu.py tools/summarize-ycsb.py
python3 tests/test_summarize_ycsb.py
```

## English

`ycsb-bench-all-database` is a Bash CLI for repeatable JDBC/YCSB database benchmarks. It packages the Doris/YCSB workflows used in this repository: single-host runs, dual-host runs, cgroup v2 cpuset isolation, user-space thread clustering, multi-client YCSB pressure, node CPU sampling, raw log collection, and CSV/Markdown summaries.

The first version is intentionally dependency-light:

- Configuration is a shell env file.
- The database interface is generic JDBC.
- Doris support is provided through example configs and `SERVER_SETUP_CMD` / `SERVER_CLEANUP_CMD` hooks.
- cgroup v2 setup is checked and used, but root-level mounting and delegation are left to the operator.

### Layout

```text
ycsb-bench-all-database/
  bin/yba
  lib/
  tools/
  examples/
  experiments/
```

### CLI

```bash
./bin/yba preflight --config examples/singlehost-cgroup2.env
./bin/yba run --config examples/singlehost-cgroup2.env
./bin/yba summarize --experiment-dir experiments/<run>
./bin/yba cleanup --config examples/singlehost-cgroup2.env
```

Environment variables override config-file values:

```bash
MATRIX="t1:1:1" OPERATIONCOUNT_PER_CLIENT=1000 \
  ./bin/yba run --config examples/dualhost-doris.env
```

### Modes

#### Single Host

`MODE=singlehost` runs the server hook and YCSB clients on `SERVER_HOST`. This is useful when you isolate resources with cgroup v2, for example Doris on NUMA nodes 0-2 and YCSB on node3.

```bash
./bin/yba run --config examples/singlehost-cgroup2.env
```

#### Dual Host

`MODE=dualhost` runs server hooks on `SERVER_HOST` and YCSB clients on `CLIENT_HOST`.

```bash
./bin/yba run --config examples/dualhost-doris.env
```

#### Thread Clustering

Thread clustering uses thread-name regex rules plus `taskset -pc` after the server is ready:

```bash
THREAD_CLUSTER_RULES='query:brpc_light|Pipe_normal|Scan_normal:32-63 background:brpc_heavy|Flush|Task:0-31'
```

Each rule is:

```text
name:comm_regex:cpu_list
```

The first version applies rules to existing TIDs once per run. If a program creates matching threads later, rerun clustering or extend the tool with a periodic binder.

### Core Configuration

```bash
MODE=singlehost|dualhost
SERVER_HOST=kunpen183
CLIENT_HOST=ubuntu197
REMOTE_ROOT=/home/xhc/ExperScript/ycsb-bench-all-database
LOCAL_RESULTS_ROOT=/data/sched-ext-study/ycsb-bench-all-database/experiments

SSH_OPTS='-F ~/.ssh/config'
SERVER_SSH_OPTS='-p 22183'
CLIENT_SSH_OPTS='-p 22197'

YCSB_HOME=/home/xhc/ycsb-jdbc-binding-0.17.0
PYTHON2_BIN=python2
JDBC_URL='jdbc:mysql://127.0.0.1:9030/ycsb?useSSL=false'
JDBC_USER=root
JDBC_PASSWORD=
JDBC_DRIVER=com.mysql.cj.jdbc.Driver
JDBC_JAR=/home/xhc/ycsb-jdbc-binding-0.17.0/lib/mysql-connector-java-8.0.28.jar
TABLE=usertable

WORKLOAD_FILE=
GENERATE_WORKLOAD=1
RECORDCOUNT=1000000
OPERATIONCOUNT_PER_CLIENT=50000
REQUEST_DISTRIBUTION=zipfian
READ_PROPORTION=1
UPDATE_PROPORTION=0
MATRIX='t80:5:16 t128:8:16'
ROUNDS=1

ENABLE_CGROUP=0
SERVER_CGROUP=/run/cgroup2/ycsb-bench/server
CLIENT_CGROUP=/run/cgroup2/ycsb-bench/client
SERVER_CPUSET_EXPECT=0-95
SERVER_MEMS_EXPECT=0-2
CLIENT_CPUSET_EXPECT=96-127
CLIENT_MEMS_EXPECT=3

ENABLE_THREAD_CLUSTER=0
THREAD_CLUSTER_RULES='query:brpc_light|Pipe_normal|Scan_normal:32-63'

SERVER_SETUP_CMD=
SERVER_READY_CMD="mysql -h127.0.0.1 -P9030 -uroot -e 'select 1'"
SERVER_CLEANUP_CMD=
SERVER_PID_COMMAND='pgrep -x doris_be'
```

`MATRIX` entries use:

```text
label:client_processes:threads_per_client
```

For example `t80:5:16` means 5 YCSB processes, 16 threads per process, 80 total client threads.

### cgroup v2 Requirements

The tool does not mount cgroup v2 or create delegated subtrees as root. Prepare them beforehand, then configure:

```bash
ENABLE_CGROUP=1
SERVER_CGROUP=/run/cgroup2/doris-bench/doris
CLIENT_CGROUP=/run/cgroup2/doris-bench/ycsb
SERVER_CPUSET_EXPECT=0-95
SERVER_MEMS_EXPECT=0-2
CLIENT_CPUSET_EXPECT=96-127
CLIENT_MEMS_EXPECT=3
```

`preflight` checks effective CPU and memory node lists. During a run, server PIDs and YCSB client shells are moved into their configured cgroups and `/proc/<pid>/status` snapshots are saved.

If cgroup writes require sudo, set:

```bash
CGROUP_WRITE_WITH_SUDO=1
SUDO_ASKPASS=/path/to/askpass.sh
```

### SSH and Jump Hosts

The tool uses the configured SSH alias by default:

```bash
SERVER_HOST=kunpen183
CLIENT_HOST=ubuntu197
```

For non-standard SSH setups, configure the transport explicitly:

```bash
SSH_BIN=ssh
SCP_BIN=scp
RSYNC_BIN=rsync
SSH_OPTS='-F /path/to/ssh_config -o BatchMode=yes'
SERVER_SSH_OPTS='-J jump-host -i ~/.ssh/server_key'
CLIENT_SSH_OPTS='-p 22197 -i ~/.ssh/client_key'
```

`SERVER_SSH_OPTS` and `CLIENT_SSH_OPTS` are appended to `SSH_OPTS` based on whether the target host equals `SERVER_HOST` or `CLIENT_HOST`. `scp` reuses the matching SSH options by default; override with `SERVER_SCP_OPTS` or `CLIENT_SCP_OPTS` if needed.

`rsync` uses the same SSH command through `-e`. Override only when your environment needs a custom remote shell:

```bash
SERVER_RSYNC_RSH='ssh -F /path/to/ssh_config -J jump-host'
CLIENT_RSYNC_RSH='ssh -F /path/to/ssh_config -p 22197'
```

### Output

Each run creates a timestamped experiment directory under `LOCAL_RESULTS_ROOT`:

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
    doris/
  summary.csv
  summary-by-label.csv
  cpu-node-summary.csv
  report.md
```

Aggregation rules:

- Throughput is summed across client logs.
- Average latency is weighted by READ operation count.
- P95/P99/P999 use the conservative max across client logs.
- Errors and timeouts are counted from raw YCSB logs.
- CPU node busy is sampled from `/proc/stat` and grouped by `lscpu -e=CPU,NODE,ONLINE`.

### Safety Notes

- The scripts avoid `pkill -f`; cleanup should use configured hooks or tracked process names.
- Remote hosts are addressed through SSH aliases such as `kunpen183` and `ubuntu197`.
- Remote hosts are execution environments. Reports and key CSV files are synchronized back to the local experiment directory.
- Thread-name matching depends on Linux `comm`, which is commonly truncated to 15 characters. Use prefixes or broad regexes when needed.
- Single-node clustering can improve medium/low-load locality but can become a bottleneck under higher load.

### Local Verification

```bash
bash -n bin/yba lib/*.sh
python3 -m py_compile tools/sample-node-cpu.py tools/summarize-ycsb.py
python3 tests/test_summarize_ycsb.py
```
