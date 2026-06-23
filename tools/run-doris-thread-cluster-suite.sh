#!/usr/bin/env bash
set -euo pipefail

YBA_ROOT=${YBA_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
CONFIG=${CONFIG:-$YBA_ROOT/examples/doris/dualhost-baseline.env}
SUITE_NAME=${SUITE_NAME:-20260623-doris-dualhost-thread-cluster-node3-node2-x3}
SUITE_DIR=${SUITE_DIR:-$YBA_ROOT/experiments/$SUITE_NAME}
OPS_PER_CLIENT=${OPS_PER_CLIENT:-50000}
RUN_SECONDS=${RUN_SECONDS:-1800}

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
            THREAD_CLUSTER_RULES='all:.*:32-63' \
            THREAD_CLUSTER_DEFAULT_CPUS= \
            THREAD_CLUSTER_STRICT=1 \
            THREAD_CLUSTER_STRICT_RULES=all \
            THREAD_CLUSTER_REQUIRE_STABLE=0 \
            THREAD_CLUSTER_MIN_HIT_RATIO=0.95 \
            SERVER_PID_COMMAND='pgrep -x doris_be' \
            SERVER_SETUP_CMD='DORIS_HOME=/home/xhc/doris/apache-doris-2.1.2-bin-arm64; numactl --cpunodebind=1 --membind=1 sh "$DORIS_HOME/fe/bin/start_fe.sh" --daemon; numactl --cpunodebind=1 --membind=1 sh "$DORIS_HOME/be/bin/start_be.sh" --daemon' \
            SERVER_CLEANUP_CMD='DORIS_HOME=/home/xhc/doris/apache-doris-2.1.2-bin-arm64; sh "$DORIS_HOME/be/bin/stop_be.sh" --daemon 2>/dev/null || true; sh "$DORIS_HOME/fe/bin/stop_fe.sh" --daemon 2>/dev/null || true' \
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
            THREAD_CLUSTER_RULES='hot:brpc_heavy|brpc_light|Pipe_normal:96-127' \
            THREAD_CLUSTER_DEFAULT_NAME=other \
            THREAD_CLUSTER_DEFAULT_CPUS=64-95 \
            THREAD_CLUSTER_STRICT=1 \
            THREAD_CLUSTER_STRICT_RULES=hot \
            THREAD_CLUSTER_MIN_HIT_RATIO=0.95 \
            SERVER_PID_COMMAND='pgrep -x doris_be' \
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
    local load matrix round profile
    for load in t16 t80; do
        case "$load" in
            t16) matrix='t16:1:16' ;;
            t80) matrix='t80:5:16' ;;
        esac
        for round in 1 2 3; do
            for profile in baseline numa_node1 cluster_hot_node3_other_node2; do
                run_one "$profile" "$load" "$matrix" "$round"
            done
        done
    done
    python3 "$YBA_ROOT/tools/summarize-suite.py" --suite-dir "$SUITE_DIR"
    echo "suite complete: $SUITE_DIR"
}

main "$@"
