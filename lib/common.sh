#!/usr/bin/env bash

yba_log() {
    echo "[$(date +'%F %T')] $*"
}

yba_die() {
    echo "ERROR: $*" >&2
    exit 1
}

yba_abs_path() {
    local path=$1
    if [[ "$path" = /* ]]; then
        echo "$path"
    else
        echo "$(pwd)/$path"
    fi
}

yba_quote() {
    printf "%q" "$1"
}

yba_load_config() {
    local file=$1
    [ -f "$file" ] || yba_die "missing config: $file"
    local -a env_overrides=()
    local line key value
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)= ]] || continue
        key=${BASH_REMATCH[1]}
        if value=$(printenv "$key" 2>/dev/null); then
            env_overrides+=("$key=$value")
        fi
    done < "$file"

    # shellcheck disable=SC1090
    set -a
    . "$file"
    set +a

    local item
    for item in "${env_overrides[@]}"; do
        key=${item%%=*}
        value=${item#*=}
        printf -v "$key" '%s' "$value"
        export "$key"
    done
}

yba_apply_defaults() {
    MODE=${MODE:-singlehost}
    SERVER_HOST=${SERVER_HOST:-localhost}
    CLIENT_HOST=${CLIENT_HOST:-$SERVER_HOST}
    TIMESTAMP=${TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}
    EXPERIMENT_NAME=${EXPERIMENT_NAME:-ycsb-bench}
    LOCAL_RESULTS_ROOT=${LOCAL_RESULTS_ROOT:-$YBA_ROOT/experiments}
    EXPERIMENT_DIR=${EXPERIMENT_DIR:-$LOCAL_RESULTS_ROOT/${TIMESTAMP}-${EXPERIMENT_NAME}}
    REMOTE_ROOT=${REMOTE_ROOT:-/tmp/ycsb-bench-all-database}
    REMOTE_EXPERIMENT_DIR=${REMOTE_EXPERIMENT_DIR:-$REMOTE_ROOT/experiments/$(basename "$EXPERIMENT_DIR")}

    SSH_BIN=${SSH_BIN:-ssh}
    SCP_BIN=${SCP_BIN:-scp}
    RSYNC_BIN=${RSYNC_BIN:-rsync}
    SSH_OPTS=${SSH_OPTS:-}
    SCP_OPTS=${SCP_OPTS:-}
    RSYNC_OPTS=${RSYNC_OPTS:-}
    RSYNC_RSH=${RSYNC_RSH:-}
    SERVER_SSH_OPTS=${SERVER_SSH_OPTS:-}
    CLIENT_SSH_OPTS=${CLIENT_SSH_OPTS:-}
    SERVER_SCP_OPTS=${SERVER_SCP_OPTS:-}
    CLIENT_SCP_OPTS=${CLIENT_SCP_OPTS:-}
    SERVER_RSYNC_RSH=${SERVER_RSYNC_RSH:-}
    CLIENT_RSYNC_RSH=${CLIENT_RSYNC_RSH:-}

    YCSB_HOME=${YCSB_HOME:-/home/xhc/ycsb-jdbc-binding-0.17.0}
    YCSB_SOURCE_HOST=${YCSB_SOURCE_HOST:-}
    YCSB_SOURCE_PATH=${YCSB_SOURCE_PATH:-$YCSB_HOME}
    PYTHON2_BIN=${PYTHON2_BIN:-python2}
    PYTHON2_LD_LIBRARY_PATH=${PYTHON2_LD_LIBRARY_PATH:-}

    JDBC_URL=${JDBC_URL:-jdbc:mysql://127.0.0.1:9030/ycsb?useSSL=false}
    JDBC_USER=${JDBC_USER:-root}
    JDBC_PASSWORD=${JDBC_PASSWORD:-}
    JDBC_DRIVER=${JDBC_DRIVER:-com.mysql.cj.jdbc.Driver}
    JDBC_JAR=${JDBC_JAR:-$YCSB_HOME/lib/mysql-connector-java-8.0.28.jar}
    DB_PROPS=${DB_PROPS:-$YCSB_HOME/conf/yba-db.properties}
    TABLE=${TABLE:-usertable}

    WORKLOAD_FILE=${WORKLOAD_FILE:-}
    GENERATE_WORKLOAD=${GENERATE_WORKLOAD:-1}
    GENERATED_WORKLOAD=${GENERATED_WORKLOAD:-$YCSB_HOME/workloads/yba-workload}
    RECORDCOUNT=${RECORDCOUNT:-1000000}
    OPERATIONCOUNT_PER_CLIENT=${OPERATIONCOUNT_PER_CLIENT:-50000}
    REQUEST_DISTRIBUTION=${REQUEST_DISTRIBUTION:-zipfian}
    READ_PROPORTION=${READ_PROPORTION:-1}
    UPDATE_PROPORTION=${UPDATE_PROPORTION:-0}
    SCAN_PROPORTION=${SCAN_PROPORTION:-0}
    INSERT_PROPORTION=${INSERT_PROPORTION:-0}
    INSERT_ORDER=${INSERT_ORDER:-ordered}

    MATRIX=${MATRIX:-t80:5:16}
    ROUNDS=${ROUNDS:-1}
    STATUS_INTERVAL=${STATUS_INTERVAL:-10}
    RUN_SECONDS=${RUN_SECONDS:-1800}

    ENABLE_CGROUP=${ENABLE_CGROUP:-0}
    CGROUP_ROOT=${CGROUP_ROOT:-/run/cgroup2/ycsb-bench}
    SERVER_CGROUP=${SERVER_CGROUP:-$CGROUP_ROOT/server}
    CLIENT_CGROUP=${CLIENT_CGROUP:-$CGROUP_ROOT/client}
    SERVER_CPUSET_EXPECT=${SERVER_CPUSET_EXPECT:-}
    SERVER_MEMS_EXPECT=${SERVER_MEMS_EXPECT:-}
    CLIENT_CPUSET_EXPECT=${CLIENT_CPUSET_EXPECT:-}
    CLIENT_MEMS_EXPECT=${CLIENT_MEMS_EXPECT:-}
    CGROUP_AUTO_CONFIG=${CGROUP_AUTO_CONFIG:-0}
    CGROUP_WRITE_WITH_SUDO=${CGROUP_WRITE_WITH_SUDO:-1}
    CGROUP_PROCS_WRITE_WITH_SUDO=${CGROUP_PROCS_WRITE_WITH_SUDO:-$CGROUP_WRITE_WITH_SUDO}
    CGROUP_PROCS_SMOKE_TEST=${CGROUP_PROCS_SMOKE_TEST:-1}
    SUDO_ASKPASS=${SUDO_ASKPASS:-}

    ENABLE_THREAD_CLUSTER=${ENABLE_THREAD_CLUSTER:-0}
    THREAD_CLUSTER_RULES=${THREAD_CLUSTER_RULES:-}
    SERVER_PID_COMMAND=${SERVER_PID_COMMAND:-pgrep -x doris_be}

    SERVER_SETUP_CMD=${SERVER_SETUP_CMD:-}
    SERVER_CLEANUP_CMD=${SERVER_CLEANUP_CMD:-}
    SERVER_READY_CMD=${SERVER_READY_CMD:-}
    CLEANUP_SERVER=${CLEANUP_SERVER:-1}
    SERVER_WARNING_LOG_GLOB=${SERVER_WARNING_LOG_GLOB:-}

    ENABLE_NODE_CPU_SAMPLER=${ENABLE_NODE_CPU_SAMPLER:-1}
    ENABLE_VMSTAT=${ENABLE_VMSTAT:-1}
    ENABLE_NUMASTAT=${ENABLE_NUMASTAT:-1}

    mkdir -p "$EXPERIMENT_DIR"
}

yba_write_kv_file() {
    local file=$1
    shift
    : > "$file"
    while [ "$#" -gt 0 ]; do
        echo "$1=$2" >> "$file"
        shift 2
    done
}
