#!/usr/bin/env bash
set -euo pipefail

YBA_ROOT=${YBA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
CONFIG=${CONFIG:-$YBA_ROOT/examples/clickhouse/dualhost-baseline.env}
SUITE_NAME=${SUITE_NAME:-20260624-clickhouse-dualhost-numa-x3}
SUITE_DIR=${SUITE_DIR:-$YBA_ROOT/experiments/$SUITE_NAME}
OPS_PER_CLIENT=${OPS_PER_CLIENT:-50000}
RUN_SECONDS=${RUN_SECONDS:-1800}
SUITE_ROUNDS=${SUITE_ROUNDS:-3}
SUITE_LOADS=${SUITE_LOADS:-"t16:t16:1:16 t80:t80:5:16"}
SUITE_PROFILES=${SUITE_PROFILES:-"baseline numa_node1"}

CLICKHOUSE_BIN=${CLICKHOUSE_BIN:-/home/xhc/clickhouse/ClickHouse/build/programs/clickhouse}
CLICKHOUSE_CLIENT=${CLICKHOUSE_CLIENT:-/home/xhc/clickhouse/ClickHouse/build/programs/clickhouse-client}
CLICKHOUSE_CONFIG=${CLICKHOUSE_CONFIG:-/home/xhc/clickhouse/etc/config.xml}
CLICKHOUSE_HOST=${CLICKHOUSE_HOST:-127.0.0.1}
CLICKHOUSE_TCP_PORT=${CLICKHOUSE_TCP_PORT:-9000}
CLICKHOUSE_MYSQL_PORT=${CLICKHOUSE_MYSQL_PORT:-9004}
CLICKHOUSE_LOG_DIR=${CLICKHOUSE_LOG_DIR:-/tmp/yba-clickhouse}
CLICKHOUSE_NUMA_NODE=${CLICKHOUSE_NUMA_NODE:-1}
CLICKHOUSE_NUMA_CPUS=${CLICKHOUSE_NUMA_CPUS:-32-63}
SERVER_PID_COMMAND=${SERVER_PID_COMMAND:-pgrep -x clickhouse-server}

print_config() {
    cat <<EOF
YBA_ROOT=$YBA_ROOT
CONFIG=$CONFIG
SUITE_NAME=$SUITE_NAME
SUITE_DIR=$SUITE_DIR
OPS_PER_CLIENT=$OPS_PER_CLIENT
RUN_SECONDS=$RUN_SECONDS
SUITE_ROUNDS=$SUITE_ROUNDS
SUITE_LOADS=$SUITE_LOADS
SUITE_PROFILES=$SUITE_PROFILES
CLICKHOUSE_BIN=$CLICKHOUSE_BIN
CLICKHOUSE_CLIENT=$CLICKHOUSE_CLIENT
CLICKHOUSE_CONFIG=$CLICKHOUSE_CONFIG
CLICKHOUSE_HOST=$CLICKHOUSE_HOST
CLICKHOUSE_TCP_PORT=$CLICKHOUSE_TCP_PORT
CLICKHOUSE_MYSQL_PORT=$CLICKHOUSE_MYSQL_PORT
CLICKHOUSE_LOG_DIR=$CLICKHOUSE_LOG_DIR
CLICKHOUSE_NUMA_NODE=$CLICKHOUSE_NUMA_NODE
CLICKHOUSE_NUMA_CPUS=$CLICKHOUSE_NUMA_CPUS
SERVER_PID_COMMAND=$SERVER_PID_COMMAND
SERVER_HOST=${SERVER_HOST:-}
CLIENT_HOST=${CLIENT_HOST:-}
JDBC_URL=${JDBC_URL:-}
EOF
}

if [ "${1:-}" = "--print-config" ]; then
    print_config
    exit 0
fi

mkdir -p "$SUITE_DIR/runs"

run_yba_cleanup() {
    ./bin/yba cleanup --config "$CONFIG" || true
}

run_one() {
    local profile=$1
    local load=$2
    local matrix=$3
    local round=$4
    local run_name="${profile}-${load}-r${round}"
    local run_dir="$SUITE_DIR/runs/$run_name"

    if [ -f "$run_dir/summary.csv" ]; then
        echo "[$(date +'%F %T')] skip completed profile=$profile load=$load round=$round"
        return 0
    fi

    echo "[$(date +'%F %T')] run profile=$profile load=$load round=$round"
    run_yba_cleanup

    case "$profile" in
        baseline)
            EXPERIMENT_NAME="$run_name" \
            EXPERIMENT_DIR="$run_dir" \
            MATRIX="$matrix" \
            ROUNDS=1 \
            OPERATIONCOUNT_PER_CLIENT="$OPS_PER_CLIENT" \
            RUN_SECONDS="$RUN_SECONDS" \
            DB_TYPE=clickhouse \
            ENABLE_THREAD_CLUSTER=0 \
            CLICKHOUSE_MODE=unrestricted \
            CLICKHOUSE_BIN="$CLICKHOUSE_BIN" \
            CLICKHOUSE_CLIENT="$CLICKHOUSE_CLIENT" \
            CLICKHOUSE_CONFIG="$CLICKHOUSE_CONFIG" \
            CLICKHOUSE_HOST="$CLICKHOUSE_HOST" \
            CLICKHOUSE_TCP_PORT="$CLICKHOUSE_TCP_PORT" \
            CLICKHOUSE_MYSQL_PORT="$CLICKHOUSE_MYSQL_PORT" \
            CLICKHOUSE_LOG_DIR="$CLICKHOUSE_LOG_DIR" \
            SERVER_PID_COMMAND="$SERVER_PID_COMMAND" \
            SERVER_SETUP_CMD= \
            SERVER_CLEANUP_CMD= \
            ./bin/yba run --config "$CONFIG"
            ;;
        numa_node1)
            EXPERIMENT_NAME="$run_name" \
            EXPERIMENT_DIR="$run_dir" \
            MATRIX="$matrix" \
            ROUNDS=1 \
            OPERATIONCOUNT_PER_CLIENT="$OPS_PER_CLIENT" \
            RUN_SECONDS="$RUN_SECONDS" \
            DB_TYPE=clickhouse \
            ENABLE_THREAD_CLUSTER=0 \
            CLICKHOUSE_MODE=node1 \
            CLICKHOUSE_NUMA_NODE="$CLICKHOUSE_NUMA_NODE" \
            CLICKHOUSE_BIN="$CLICKHOUSE_BIN" \
            CLICKHOUSE_CLIENT="$CLICKHOUSE_CLIENT" \
            CLICKHOUSE_CONFIG="$CLICKHOUSE_CONFIG" \
            CLICKHOUSE_HOST="$CLICKHOUSE_HOST" \
            CLICKHOUSE_TCP_PORT="$CLICKHOUSE_TCP_PORT" \
            CLICKHOUSE_MYSQL_PORT="$CLICKHOUSE_MYSQL_PORT" \
            CLICKHOUSE_LOG_DIR="$CLICKHOUSE_LOG_DIR" \
            SERVER_PID_COMMAND="$SERVER_PID_COMMAND" \
            SERVER_SETUP_CMD= \
            SERVER_CLEANUP_CMD= \
            ./bin/yba run --config "$CONFIG"
            ;;
        nodes:*)
            EXPERIMENT_NAME="$run_name" \
            EXPERIMENT_DIR="$run_dir" \
            MATRIX="$matrix" \
            ROUNDS=1 \
            OPERATIONCOUNT_PER_CLIENT="$OPS_PER_CLIENT" \
            RUN_SECONDS="$RUN_SECONDS" \
            DB_TYPE=clickhouse \
            ENABLE_THREAD_CLUSTER=0 \
            CLICKHOUSE_MODE="$profile" \
            CLICKHOUSE_BIN="$CLICKHOUSE_BIN" \
            CLICKHOUSE_CLIENT="$CLICKHOUSE_CLIENT" \
            CLICKHOUSE_CONFIG="$CLICKHOUSE_CONFIG" \
            CLICKHOUSE_HOST="$CLICKHOUSE_HOST" \
            CLICKHOUSE_TCP_PORT="$CLICKHOUSE_TCP_PORT" \
            CLICKHOUSE_MYSQL_PORT="$CLICKHOUSE_MYSQL_PORT" \
            CLICKHOUSE_LOG_DIR="$CLICKHOUSE_LOG_DIR" \
            SERVER_PID_COMMAND="$SERVER_PID_COMMAND" \
            SERVER_SETUP_CMD= \
            SERVER_CLEANUP_CMD= \
            ./bin/yba run --config "$CONFIG"
            ;;
        *)
            echo "unknown profile: $profile" >&2
            exit 2
            ;;
    esac

    run_yba_cleanup
}

main() {
    cd "$YBA_ROOT"
    local load_spec load matrix_label clients threads matrix round profile
    for load_spec in $SUITE_LOADS; do
        IFS=: read -r load matrix_label clients threads <<EOF
$load_spec
EOF
        [ -n "$load" ] && [ -n "$matrix_label" ] && [ -n "$clients" ] && [ -n "$threads" ] || {
            echo "bad SUITE_LOADS item: $load_spec" >&2
            exit 2
        }
        matrix="$matrix_label:$clients:$threads"
        for round in $(seq 1 "$SUITE_ROUNDS"); do
            for profile in $SUITE_PROFILES; do
                run_one "$profile" "$load" "$matrix" "$round"
            done
        done
    done
    python3 "$YBA_ROOT/tools/summarize-suite.py" \
        --suite-dir "$SUITE_DIR" \
        --server-host "${SERVER_HOST:-kunpen183}" \
        --client-host "${CLIENT_HOST:-ubuntu197}" \
        --database-name ClickHouse \
        --report-title "ClickHouse/YCSB 双机 NUMA 对照测试报告" \
        --report-file "$SUITE_DIR/clickhouse-numa-suite-report-cn.md" \
        --summary-file "$SUITE_DIR/clickhouse-numa-suite-summary.csv" \
        --aggregate-file "$SUITE_DIR/clickhouse-numa-suite-summary-by-profile-load.csv" \
        --numa-control-cpus "$CLICKHOUSE_NUMA_CPUS"
    echo "suite complete: $SUITE_DIR"
}

main "$@"
