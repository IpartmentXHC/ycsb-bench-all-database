#!/usr/bin/env bash

yba_cgroup_write_pid() {
    local pid=$1
    local cgroup=$2
    [ -d "$cgroup" ] || yba_die "missing cgroup: $cgroup"
    if [ "$CGROUP_WRITE_WITH_SUDO" = "1" ]; then
        if [ -n "$SUDO_ASKPASS" ]; then
            printf '%s\n' "$pid" | SUDO_ASKPASS="$SUDO_ASKPASS" sudo -A tee "$cgroup/cgroup.procs" >/dev/null
        else
            printf '%s\n' "$pid" | sudo tee "$cgroup/cgroup.procs" >/dev/null
        fi
    else
        printf '%s\n' "$pid" > "$cgroup/cgroup.procs"
    fi
}

yba_verify_proc_allowed() {
    local pid=$1
    local cpus=$2
    local mems=$3
    local out=$4
    grep -E 'Name|Pid|Cpus_allowed_list|Mems_allowed_list' "/proc/$pid/status" >> "$out" || true
    if [ -n "$cpus" ]; then
        grep -q "Cpus_allowed_list:[[:space:]]*$cpus" "$out" || yba_die "pid $pid CPU cgroup verification failed"
    fi
    if [ -n "$mems" ]; then
        grep -q "Mems_allowed_list:[[:space:]]*$mems" "$out" || yba_die "pid $pid mem cgroup verification failed"
    fi
}

yba_preflight_cgroup() {
    [ "$ENABLE_CGROUP" = "1" ] || return 0
    [ -d "$SERVER_CGROUP" ] || yba_die "missing SERVER_CGROUP: $SERVER_CGROUP"
    [ -d "$CLIENT_CGROUP" ] || yba_die "missing CLIENT_CGROUP: $CLIENT_CGROUP"
    if [ -n "$SERVER_CPUSET_EXPECT" ]; then
        [ "$(cat "$SERVER_CGROUP/cpuset.cpus.effective")" = "$SERVER_CPUSET_EXPECT" ] || yba_die "unexpected server cpuset"
    fi
    if [ -n "$SERVER_MEMS_EXPECT" ]; then
        [ "$(cat "$SERVER_CGROUP/cpuset.mems.effective")" = "$SERVER_MEMS_EXPECT" ] || yba_die "unexpected server mems"
    fi
    if [ -n "$CLIENT_CPUSET_EXPECT" ]; then
        [ "$(cat "$CLIENT_CGROUP/cpuset.cpus.effective")" = "$CLIENT_CPUSET_EXPECT" ] || yba_die "unexpected client cpuset"
    fi
    if [ -n "$CLIENT_MEMS_EXPECT" ]; then
        [ "$(cat "$CLIENT_CGROUP/cpuset.mems.effective")" = "$CLIENT_MEMS_EXPECT" ] || yba_die "unexpected client mems"
    fi
}

yba_move_server_pids_to_cgroup() {
    [ "$ENABLE_CGROUP" = "1" ] || return 0
    local pid
    for pid in $(bash -lc "$SERVER_PID_COMMAND" 2>/dev/null || true); do
        yba_cgroup_write_pid "$pid" "$SERVER_CGROUP"
    done
}

yba_snapshot_server_cgroup() {
    local dir=$1
    mkdir -p "$dir/cgroup"
    : > "$dir/cgroup/server-proc-status.txt"
    local pid
    for pid in $(bash -lc "$SERVER_PID_COMMAND" 2>/dev/null || true); do
        echo "===== pid=$pid =====" >> "$dir/cgroup/server-proc-status.txt"
        yba_verify_proc_allowed "$pid" "$SERVER_CPUSET_EXPECT" "$SERVER_MEMS_EXPECT" "$dir/cgroup/server-proc-status.txt"
    done
}

yba_apply_thread_cluster() {
    [ "$ENABLE_THREAD_CLUSTER" = "1" ] || return 0
    [ -n "$THREAD_CLUSTER_RULES" ] || return 0
    local dir=$1
    mkdir -p "$dir/thread-cluster"
    local pid rule name regex cpus tid
    for pid in $(bash -lc "$SERVER_PID_COMMAND" 2>/dev/null || true); do
        ps -T -p "$pid" -o tid=,comm= > "$dir/thread-cluster/before-${pid}.txt" || true
        for rule in $THREAD_CLUSTER_RULES; do
            name=${rule%%:*}
            rest=${rule#*:}
            regex=${rest%:*}
            cpus=${rest##*:}
            ps -T -p "$pid" -o tid=,comm= | awk -v re="$regex" '$2 ~ re {print $1}' |
                while read -r tid; do
                    [ -n "$tid" ] || continue
                    echo "$name pid=$pid tid=$tid cpus=$cpus" >> "$dir/thread-cluster/actions.log"
                    taskset -pc "$cpus" "$tid" >> "$dir/thread-cluster/actions.log" 2>&1 || true
                done
        done
        ps -T -p "$pid" -o tid=,comm=,psr= > "$dir/thread-cluster/after-${pid}.txt" || true
    done
}
