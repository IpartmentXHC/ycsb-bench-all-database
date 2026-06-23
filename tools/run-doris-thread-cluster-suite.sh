#!/usr/bin/env bash
set -euo pipefail

YBA_ROOT=${YBA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
CONFIG=${CONFIG:-$YBA_ROOT/examples/doris/dualhost-baseline.env}
SUITE_NAME=${SUITE_NAME:-20260623-doris-dualhost-thread-cluster-node3-node2-x3}
SUITE_DIR=${SUITE_DIR:-$YBA_ROOT/experiments/$SUITE_NAME}
OPS_PER_CLIENT=${OPS_PER_CLIENT:-50000}
RUN_SECONDS=${RUN_SECONDS:-1800}
SUITE_ROUNDS=${SUITE_ROUNDS:-3}
SUITE_LOADS=${SUITE_LOADS:-"t16:t16:1:16 t80:t80:5:16"}
SUITE_PROFILES=${SUITE_PROFILES:-"baseline numa_node1 cluster_hot_node3_other_node2"}

DORIS_HOME=${DORIS_HOME:-/home/xhc/doris/apache-doris-2.1.2-bin-arm64}
NUMA_CONTROL_NODE=${NUMA_CONTROL_NODE:-1}
NUMA_CONTROL_CPUS=${NUMA_CONTROL_CPUS:-32-63}
HOT_THREAD_REGEX=${HOT_THREAD_REGEX:-brpc_heavy|brpc_light|Pipe_normal}
HOT_NODE_CPUS=${HOT_NODE_CPUS:-96-127}
OTHER_NODE_CPUS=${OTHER_NODE_CPUS:-64-95}
SERVER_PID_COMMAND=${SERVER_PID_COMMAND:-pgrep -x doris_be}

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
DORIS_HOME=$DORIS_HOME
NUMA_CONTROL_NODE=$NUMA_CONTROL_NODE
NUMA_CONTROL_CPUS=$NUMA_CONTROL_CPUS
HOT_THREAD_REGEX=$HOT_THREAD_REGEX
HOT_NODE_CPUS=$HOT_NODE_CPUS
OTHER_NODE_CPUS=$OTHER_NODE_CPUS
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
            ENABLE_THREAD_CLUSTER=0 \
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
            ENABLE_THREAD_CLUSTER=1 \
            THREAD_CLUSTER_RULES="all:.*:$NUMA_CONTROL_CPUS" \
            THREAD_CLUSTER_DEFAULT_CPUS= \
            THREAD_CLUSTER_STRICT=1 \
            THREAD_CLUSTER_STRICT_RULES=all \
            THREAD_CLUSTER_REQUIRE_STABLE=0 \
            THREAD_CLUSTER_MIN_HIT_RATIO=0.95 \
            SERVER_PID_COMMAND="$SERVER_PID_COMMAND" \
            SERVER_SETUP_CMD="DORIS_HOME=$(printf '%q' "$DORIS_HOME"); numactl --cpunodebind=$NUMA_CONTROL_NODE --membind=$NUMA_CONTROL_NODE sh \"\$DORIS_HOME/fe/bin/start_fe.sh\" --daemon; numactl --cpunodebind=$NUMA_CONTROL_NODE --membind=$NUMA_CONTROL_NODE sh \"\$DORIS_HOME/be/bin/start_be.sh\" --daemon" \
            SERVER_CLEANUP_CMD="DORIS_HOME=$(printf '%q' "$DORIS_HOME"); sh \"\$DORIS_HOME/be/bin/stop_be.sh\" --daemon 2>/dev/null || true; sh \"\$DORIS_HOME/fe/bin/stop_fe.sh\" --daemon 2>/dev/null || true" \
            ./bin/yba run --config "$CONFIG"
            ;;
        cluster_hot_node3_other_node2)
            EXPERIMENT_NAME="$run_name" \
            EXPERIMENT_DIR="$run_dir" \
            MATRIX="$matrix" \
            ROUNDS=1 \
            OPERATIONCOUNT_PER_CLIENT="$OPS_PER_CLIENT" \
            RUN_SECONDS="$RUN_SECONDS" \
            ENABLE_THREAD_CLUSTER=1 \
            THREAD_CLUSTER_RULES="hot:$HOT_THREAD_REGEX:$HOT_NODE_CPUS" \
            THREAD_CLUSTER_DEFAULT_NAME=other \
            THREAD_CLUSTER_DEFAULT_CPUS="$OTHER_NODE_CPUS" \
            THREAD_CLUSTER_STRICT=1 \
            THREAD_CLUSTER_STRICT_RULES=hot \
            THREAD_CLUSTER_MIN_HIT_RATIO=0.95 \
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
        --server-host "${SERVER_HOST:-}" \
        --client-host "${CLIENT_HOST:-}" \
        --hot-node-cpus "$HOT_NODE_CPUS" \
        --other-node-cpus "$OTHER_NODE_CPUS" \
        --numa-control-cpus "$NUMA_CONTROL_CPUS"
    echo "suite complete: $SUITE_DIR"
}

main "$@"
