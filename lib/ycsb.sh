#!/usr/bin/env bash

yba_remote_tools_archive() {
    local out=$1
    tar -C "$YBA_ROOT" --exclude='__pycache__' -czf "$out" bin lib tools
}

yba_install_remote_tools() {
    local host=$1
    local tmp
    tmp=$(mktemp)
    yba_remote_tools_archive "$tmp"
    if yba_is_local_host "$host"; then
        mkdir -p "$REMOTE_ROOT"
        tar -xzf "$tmp" -C "$REMOTE_ROOT"
    else
        yba_host_run "$host" "mkdir -p $(yba_quote "$REMOTE_ROOT")"
        yba_host_copy_to "$tmp" "$host" "$REMOTE_ROOT/yba-tools.tgz"
        yba_host_run "$host" "tar -xzf $(yba_quote "$REMOTE_ROOT/yba-tools.tgz") -C $(yba_quote "$REMOTE_ROOT")"
    fi
    rm -f "$tmp"
}

yba_preflight_host_basic() {
    local host=$1
    yba_host_run "$host" "set -e; hostname; uname -a; command -v bash; command -v python3"
}

yba_preflight_host_ycsb() {
    local host=$1
    yba_preflight_host_basic "$host"
    yba_host_run "$host" "set -e; test -x $(yba_quote "$YCSB_HOME/bin/ycsb"); test -f $(yba_quote "$JDBC_JAR")"
}

yba_preflight() {
    yba_log "preflight mode=$MODE server=$SERVER_HOST client=$CLIENT_HOST"
    case "$MODE" in
        singlehost|dualhost) ;;
        *) yba_die "MODE must be singlehost or dualhost, got: $MODE" ;;
    esac
    if [ "$MODE" = "singlehost" ]; then
        yba_preflight_host_ycsb "$SERVER_HOST"
    else
        yba_preflight_host_basic "$SERVER_HOST"
        yba_preflight_host_ycsb "$CLIENT_HOST"
    fi
    if [ "$ENABLE_CGROUP" = "1" ]; then
        REMOTE_EXPERIMENT_DIR="$REMOTE_ROOT/preflight"
        export REMOTE_EXPERIMENT_DIR
        yba_install_remote_tools "$SERVER_HOST"
        if [ "$MODE" = "dualhost" ] && [ "$CLIENT_HOST" != "$SERVER_HOST" ]; then
            yba_install_remote_tools "$CLIENT_HOST"
        fi
        local cgroup_host=$SERVER_HOST
        [ "$MODE" = "dualhost" ] && cgroup_host=$CLIENT_HOST
        yba_host_run "$SERVER_HOST" "$(yba_remote_env_prefix) bash -lc 'source \"\$YBA_ROOT/lib/common.sh\"; source \"\$YBA_ROOT/lib/cgroup.sh\"; yba_preflight_cgroup'"
        if [ "$MODE" = "dualhost" ] && [ "$CLIENT_HOST" != "$SERVER_HOST" ]; then
            yba_host_run "$cgroup_host" "$(yba_remote_env_prefix) bash -lc 'source \"\$YBA_ROOT/lib/common.sh\"; source \"\$YBA_ROOT/lib/cgroup.sh\"; yba_preflight_cgroup'"
        fi
    fi
    yba_log "preflight finished"
}

yba_write_jdbc_props() {
    mkdir -p "$(dirname "$DB_PROPS")"
    cat > "$DB_PROPS" <<EOF
db.driver=${JDBC_DRIVER}
db.url=${JDBC_URL}
db.user=${JDBC_USER}
db.passwd=${JDBC_PASSWORD}
EOF
}

yba_write_workload() {
    if [ -n "$WORKLOAD_FILE" ]; then
        return 0
    fi
    [ "$GENERATE_WORKLOAD" = "1" ] || yba_die "WORKLOAD_FILE is empty and GENERATE_WORKLOAD is not enabled"
    mkdir -p "$(dirname "$GENERATED_WORKLOAD")"
    cat > "$GENERATED_WORKLOAD" <<EOF
recordcount=${RECORDCOUNT}
operationcount=${OPERATIONCOUNT_PER_CLIENT}
workload=site.ycsb.workloads.CoreWorkload
readallfields=true
readproportion=${READ_PROPORTION}
updateproportion=${UPDATE_PROPORTION}
scanproportion=${SCAN_PROPORTION}
insertproportion=${INSERT_PROPORTION}
requestdistribution=${REQUEST_DISTRIBUTION}
insertorder=${INSERT_ORDER}
EOF
    WORKLOAD_FILE=$GENERATED_WORKLOAD
}

yba_write_meta_common() {
    local run_dir=$1
    mkdir -p "$run_dir"/{meta,metrics/ycsb-raw,cgroup,thread-cluster,doris}
    hostname > "$run_dir/meta/hostname.txt" 2>&1 || true
    uname -a > "$run_dir/meta/uname.txt" 2>&1 || true
    lscpu > "$run_dir/meta/lscpu.txt" 2>&1 || true
    lscpu -e=CPU,NODE,SOCKET,CORE,ONLINE > "$run_dir/meta/lscpu-e.txt" 2>&1 || true
    numactl --hardware > "$run_dir/meta/numactl-hardware.txt" 2>&1 || true
    {
        echo "MODE=$MODE"
        echo "SERVER_HOST=$SERVER_HOST"
        echo "CLIENT_HOST=$CLIENT_HOST"
        echo "YCSB_HOME=$YCSB_HOME"
        echo "JDBC_URL=$JDBC_URL"
        echo "TABLE=$TABLE"
        echo "ENABLE_CGROUP=$ENABLE_CGROUP"
        echo "SERVER_CGROUP=$SERVER_CGROUP"
        echo "CLIENT_CGROUP=$CLIENT_CGROUP"
        echo "ENABLE_THREAD_CLUSTER=$ENABLE_THREAD_CLUSTER"
        echo "THREAD_CLUSTER_RULES=$THREAD_CLUSTER_RULES"
    } > "$run_dir/meta/config-effective.env"
    if [ "$ENABLE_CGROUP" = "1" ]; then
        {
            echo "server_cgroup=$SERVER_CGROUP"
            echo "server_cpus=$(cat "$SERVER_CGROUP/cpuset.cpus.effective" 2>/dev/null || true)"
            echo "server_mems=$(cat "$SERVER_CGROUP/cpuset.mems.effective" 2>/dev/null || true)"
            echo "client_cgroup=$CLIENT_CGROUP"
            echo "client_cpus=$(cat "$CLIENT_CGROUP/cpuset.cpus.effective" 2>/dev/null || true)"
            echo "client_mems=$(cat "$CLIENT_CGROUP/cpuset.mems.effective" 2>/dev/null || true)"
        } > "$run_dir/meta/cgroup-effective.txt"
    fi
}

yba_write_workload_meta() {
    local run_dir=$1
    local label=$2
    local clients=$3
    local threads=$4
    local total=$((clients * threads))
    {
        echo "label=$label"
        echo "clients=$clients"
        echo "threads_per_client=$threads"
        echo "total_threads=$total"
        echo "ops_per_client=$OPERATIONCOUNT_PER_CLIENT"
        echo "recordcount=$RECORDCOUNT"
        echo "request_distribution=$REQUEST_DISTRIBUTION"
        echo "read_proportion=$READ_PROPORTION"
        echo "update_proportion=$UPDATE_PROPORTION"
        echo "workload_file=$WORKLOAD_FILE"
        echo "db_props=$DB_PROPS"
    } > "$run_dir/meta/workload.env"
}

yba_server_pids() {
    bash -lc "$SERVER_PID_COMMAND" 2>/dev/null || true
}

yba_setup_server() {
    if [ -n "$SERVER_SETUP_CMD" ]; then
        yba_log "server setup hook"
        bash -lc "$SERVER_SETUP_CMD"
    fi
    if [ "$ENABLE_CGROUP" = "1" ]; then
        yba_move_server_pids_to_cgroup
    fi
    if [ -n "$SERVER_READY_CMD" ]; then
        yba_log "server ready check"
        bash -lc "$SERVER_READY_CMD"
    fi
}

yba_cleanup_local() {
    if [ "$CLEANUP_SERVER" = "1" ] && [ -n "$SERVER_CLEANUP_CMD" ]; then
        yba_log "server cleanup hook"
        bash -lc "$SERVER_CLEANUP_CMD" || true
    fi
}

yba_run_ycsb_clients() {
    local run_dir=$1
    local clients=$2
    local threads=$3
    local idx pid rc=0
    : > "$run_dir/meta/ycsb-shell-pids.txt"
    for idx in $(seq 1 "$clients"); do
        (
            if [ "$ENABLE_CGROUP" = "1" ]; then
                yba_cgroup_write_pid "$BASHPID" "$CLIENT_CGROUP"
            fi
            if [ -n "$PYTHON2_LD_LIBRARY_PATH" ]; then
                export LD_LIBRARY_PATH="$PYTHON2_LD_LIBRARY_PATH:${LD_LIBRARY_PATH:-}"
            fi
            cd "$YCSB_HOME"
            exec "$PYTHON2_BIN" ./bin/ycsb run jdbc -s \
                -P "$WORKLOAD_FILE" \
                -P "$DB_PROPS" \
                -cp "$JDBC_JAR" \
                -p table="$TABLE" \
                -threads "$threads" \
                -p status.interval="$STATUS_INTERVAL"
        ) > "$run_dir/metrics/ycsb-raw/client-${idx}.log" 2>&1 &
        echo $! >> "$run_dir/meta/ycsb-shell-pids.txt"
    done

    sleep 3
    ps -eo pid,ppid,psr,pcpu,pmem,comm,args --sort=-pcpu | head -120 > "$run_dir/metrics/ps-top-during-ycsb.log" 2>&1 || true
    if [ "$ENABLE_CGROUP" = "1" ]; then
        : > "$run_dir/cgroup/client-proc-status.txt"
        local ypid
        for ypid in $(pgrep -f 'site[.]ycsb[.]Client' 2>/dev/null || true); do
            echo "===== pid=$ypid =====" >> "$run_dir/cgroup/client-proc-status.txt"
            yba_verify_proc_allowed "$ypid" "$CLIENT_CPUSET_EXPECT" "$CLIENT_MEMS_EXPECT" "$run_dir/cgroup/client-proc-status.txt"
        done
        cat "$CLIENT_CGROUP/cgroup.procs" > "$run_dir/cgroup/client-cgroup.procs.txt" 2>/dev/null || true
    fi

    while read -r pid; do
        [ -n "$pid" ] || continue
        if ! wait "$pid"; then
            rc=1
        fi
    done < "$run_dir/meta/ycsb-shell-pids.txt"
    return "$rc"
}

yba_collect_server_logs() {
    local run_dir=$1
    if [ -n "$SERVER_WARNING_LOG_GLOB" ]; then
        # shellcheck disable=SC2086
        grep -Ei 'warn|error|exception|timeout|fail|memory|spill|connection' $SERVER_WARNING_LOG_GLOB 2>/dev/null |
            tail -300 > "$run_dir/doris/server-warning.log" || true
    fi
    local pid
    : > "$run_dir/meta/server-pids.txt"
    for pid in $(yba_server_pids); do
        echo "$pid" >> "$run_dir/meta/server-pids.txt"
    done
}

yba_run_one_local() {
    local label=$1
    local clients=$2
    local threads=$3
    local round=$4
    local run_dir="$EXPERIMENT_DIR/$label/r$round"
    yba_log "run label=$label round=$round clients=$clients threads/client=$threads"
    rm -rf "$run_dir"
    yba_write_meta_common "$run_dir"
    yba_write_workload_meta "$run_dir" "$label" "$clients" "$threads"
    yba_collect_server_logs "$run_dir"
    if [ "$ENABLE_CGROUP" = "1" ]; then
        yba_snapshot_server_cgroup "$run_dir"
    fi
    ps -eo pid,tid,psr,pcpu,pmem,comm,args --sort=-pcpu | head -200 > "$run_dir/metrics/ps-thread-before.log" 2>&1 || true
    yba_apply_thread_cluster "$run_dir"
    yba_start_metrics "$run_dir"
    local rc=0
    if ! yba_run_ycsb_clients "$run_dir" "$clients" "$threads"; then
        rc=1
    fi
    yba_stop_metrics "$run_dir"
    yba_collect_server_logs "$run_dir"
    ps -eo pid,tid,psr,pcpu,pmem,comm,args --sort=-pcpu | head -200 > "$run_dir/metrics/ps-thread-after.log" 2>&1 || true
    return "$rc"
}

yba_prepare_local() {
    mkdir -p "$EXPERIMENT_DIR"
    yba_write_jdbc_props
    yba_write_workload
    yba_setup_server
}

yba_run_local_matrix() {
    yba_prepare_local
    local item label clients threads round rc=0
    for item in $MATRIX; do
        IFS=: read -r label clients threads <<EOF
$item
EOF
        [ -n "$label" ] && [ -n "$clients" ] && [ -n "$threads" ] || yba_die "bad MATRIX item: $item"
        for round in $(seq 1 "$ROUNDS"); do
            if ! yba_run_one_local "$label" "$clients" "$threads" "$round"; then
                rc=1
                break 2
            fi
        done
    done
    yba_summarize "$EXPERIMENT_DIR" || true
    return "$rc"
}

yba_fetch_results_from() {
    local host=$1
    yba_host_rsync_from "$host" "$REMOTE_EXPERIMENT_DIR" "$EXPERIMENT_DIR"
}

yba_run_remote_on() {
    local host=$1
    REMOTE_EXPERIMENT_DIR="$REMOTE_ROOT/experiments/$(basename "$EXPERIMENT_DIR")"
    export REMOTE_EXPERIMENT_DIR
    yba_install_remote_tools "$host"
    yba_host_run "$host" "$(yba_remote_env_prefix) bash -lc 'source \"\$YBA_ROOT/lib/common.sh\"; source \"\$YBA_ROOT/lib/ssh.sh\"; source \"\$YBA_ROOT/lib/cgroup.sh\"; source \"\$YBA_ROOT/lib/metrics.sh\"; source \"\$YBA_ROOT/lib/report.sh\"; source \"\$YBA_ROOT/lib/ycsb.sh\"; yba_apply_defaults; yba_run_local_matrix'"
    yba_fetch_results_from "$host"
}

yba_run_dualhost() {
    REMOTE_EXPERIMENT_DIR="$REMOTE_ROOT/experiments/$(basename "$EXPERIMENT_DIR")"
    export REMOTE_EXPERIMENT_DIR
    yba_install_remote_tools "$SERVER_HOST"
    yba_install_remote_tools "$CLIENT_HOST"
    yba_host_run "$SERVER_HOST" "$(yba_remote_env_prefix) bash -lc 'source \"\$YBA_ROOT/lib/common.sh\"; source \"\$YBA_ROOT/lib/cgroup.sh\"; source \"\$YBA_ROOT/lib/ycsb.sh\"; source \"\$YBA_ROOT/lib/metrics.sh\"; yba_apply_defaults; yba_setup_server'"

    local item label clients threads round rc=0
    for item in $MATRIX; do
        IFS=: read -r label clients threads <<EOF
$item
EOF
        [ -n "$label" ] && [ -n "$clients" ] && [ -n "$threads" ] || yba_die "bad MATRIX item: $item"
        for round in $(seq 1 "$ROUNDS"); do
            yba_log "dualhost run label=$label round=$round clients=$clients threads/client=$threads"
            yba_host_run "$SERVER_HOST" "$(yba_remote_env_prefix) bash -lc 'source \"\$YBA_ROOT/lib/common.sh\"; source \"\$YBA_ROOT/lib/cgroup.sh\"; source \"\$YBA_ROOT/lib/metrics.sh\"; source \"\$YBA_ROOT/lib/ycsb.sh\"; yba_apply_defaults; run_dir=\"\$EXPERIMENT_DIR/server/$(yba_quote "$label")/r$(yba_quote "$round")\"; rm -rf \"\$run_dir\"; yba_write_meta_common \"\$run_dir\"; yba_write_workload_meta \"\$run_dir\" $(yba_quote "$label") $(yba_quote "$clients") $(yba_quote "$threads"); yba_collect_server_logs \"\$run_dir\"; if [ \"\$ENABLE_CGROUP\" = 1 ]; then yba_snapshot_server_cgroup \"\$run_dir\"; fi; yba_apply_thread_cluster \"\$run_dir\"; yba_start_metrics \"\$run_dir\"'"
            if yba_host_run "$CLIENT_HOST" "$(yba_remote_env_prefix) MODE=singlehost SERVER_HOST=$(yba_quote "$CLIENT_HOST") CLIENT_HOST=$(yba_quote "$CLIENT_HOST") ENABLE_THREAD_CLUSTER=0 SERVER_SETUP_CMD= SERVER_READY_CMD= SERVER_CLEANUP_CMD= bash -lc 'source \"\$YBA_ROOT/lib/common.sh\"; source \"\$YBA_ROOT/lib/ssh.sh\"; source \"\$YBA_ROOT/lib/cgroup.sh\"; source \"\$YBA_ROOT/lib/metrics.sh\"; source \"\$YBA_ROOT/lib/report.sh\"; source \"\$YBA_ROOT/lib/ycsb.sh\"; yba_apply_defaults; yba_prepare_local; yba_run_one_local $(yba_quote "$label") $(yba_quote "$clients") $(yba_quote "$threads") $(yba_quote "$round"); yba_summarize \"\$EXPERIMENT_DIR\" || true'"; then
                :
            else
                rc=1
            fi
            yba_host_run "$SERVER_HOST" "$(yba_remote_env_prefix) bash -lc 'source \"\$YBA_ROOT/lib/common.sh\"; source \"\$YBA_ROOT/lib/metrics.sh\"; source \"\$YBA_ROOT/lib/ycsb.sh\"; yba_apply_defaults; run_dir=\"\$EXPERIMENT_DIR/server/$(yba_quote "$label")/r$(yba_quote "$round")\"; yba_stop_metrics \"\$run_dir\"; yba_collect_server_logs \"\$run_dir\"'" || true
            [ "$rc" = "0" ] || break 2
        done
    done
    yba_fetch_results_from "$CLIENT_HOST"
    yba_host_rsync_from "$SERVER_HOST" "$REMOTE_EXPERIMENT_DIR/server" "$EXPERIMENT_DIR/server" || true
    yba_summarize "$EXPERIMENT_DIR" || true
    return "$rc"
}

yba_run() {
    case "$MODE" in
        singlehost)
            if yba_is_local_host "$SERVER_HOST"; then
                yba_run_local_matrix
            else
                yba_run_remote_on "$SERVER_HOST"
            fi
            ;;
        dualhost)
            yba_run_dualhost
            ;;
        *)
            yba_die "MODE must be singlehost or dualhost, got: $MODE"
            ;;
    esac
}

yba_cleanup() {
    if [ "$MODE" = "singlehost" ]; then
        if yba_is_local_host "$SERVER_HOST"; then
            yba_cleanup_local
        else
            yba_install_remote_tools "$SERVER_HOST"
            yba_host_run "$SERVER_HOST" "$(yba_remote_env_prefix) bash -lc 'source \"\$YBA_ROOT/lib/common.sh\"; source \"\$YBA_ROOT/lib/ycsb.sh\"; yba_apply_defaults; yba_cleanup_local'"
        fi
    else
        yba_install_remote_tools "$SERVER_HOST"
        yba_host_run "$SERVER_HOST" "$(yba_remote_env_prefix) bash -lc 'source \"\$YBA_ROOT/lib/common.sh\"; source \"\$YBA_ROOT/lib/ycsb.sh\"; yba_apply_defaults; yba_cleanup_local'"
    fi
}
