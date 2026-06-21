#!/usr/bin/env bash

yba_cgroup_write_pid() {
    local pid=$1
    local cgroup=$2
    [ -d "$cgroup" ] || yba_die "missing cgroup: $cgroup"
    local err
    err=$(mktemp)
    if [ "$CGROUP_PROCS_WRITE_WITH_SUDO" = "1" ]; then
        if [ -n "$SUDO_ASKPASS" ]; then
            if ! printf '%s\n' "$pid" | SUDO_ASKPASS="$SUDO_ASKPASS" sudo -A tee "$cgroup/cgroup.procs" >/dev/null 2>"$err"; then
                yba_cgroup_pid_write_hint "$pid" "$cgroup" "$err"
                rm -f "$err"
                return 1
            fi
        else
            if ! printf '%s\n' "$pid" | sudo tee "$cgroup/cgroup.procs" >/dev/null 2>"$err"; then
                yba_cgroup_pid_write_hint "$pid" "$cgroup" "$err"
                rm -f "$err"
                return 1
            fi
        fi
    else
        if ! printf '%s\n' "$pid" > "$cgroup/cgroup.procs" 2>"$err"; then
            yba_cgroup_pid_write_hint "$pid" "$cgroup" "$err"
            rm -f "$err"
            return 1
        fi
    fi
    rm -f "$err"
}

yba_cgroup_pid_write_hint() {
    local pid=$1
    local cgroup=$2
    local err=$3
    cat >&2 <<EOF
ERROR: cannot move pid $pid into $cgroup/cgroup.procs as $(id -un).
$(cat "$err" 2>/dev/null || true)
This usually means cpuset files are writable, but cgroup v2 process migration is not delegated for this session.
Try one of:
  CGROUP_PROCS_WRITE_WITH_SUDO=1
  run the benchmark from a shell already inside a delegated child cgroup
  ask root to delegate the common ancestor cgroup.procs permission for this subtree
EOF
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

yba_cgroup_value() {
    local cgroup=$1
    local name=$2
    if [ -f "$cgroup/${name}.effective" ]; then
        cat "$cgroup/${name}.effective"
    elif [ -f "$cgroup/$name" ]; then
        cat "$cgroup/$name"
    else
        echo ""
    fi
}

yba_cgroup_write_file() {
    local file=$1
    local value=$2
    if [ "$CGROUP_WRITE_WITH_SUDO" = "1" ]; then
        if [ -n "$SUDO_ASKPASS" ]; then
            printf '%s\n' "$value" | SUDO_ASKPASS="$SUDO_ASKPASS" sudo -A tee "$file" >/dev/null
        else
            printf '%s\n' "$value" | sudo tee "$file" >/dev/null
        fi
    else
        printf '%s\n' "$value" > "$file"
    fi
}

yba_cgroup_config_hint() {
    cat >&2 <<EOF
Recommended cgroup v2 setup:
  sudo mkdir -p $(yba_quote "$SERVER_CGROUP") $(yba_quote "$CLIENT_CGROUP")
  sudo chown -R $(id -un):$(id -gn) $(yba_quote "$CGROUP_ROOT")
  echo 0-127 > $(yba_quote "$CGROUP_ROOT")/cpuset.cpus
  echo 0-3 > $(yba_quote "$CGROUP_ROOT")/cpuset.mems
  echo +cpuset > $(yba_quote "$CGROUP_ROOT")/cgroup.subtree_control
  echo $(yba_quote "$SERVER_CPUSET_EXPECT") > $(yba_quote "$SERVER_CGROUP")/cpuset.cpus
  echo $(yba_quote "$SERVER_MEMS_EXPECT") > $(yba_quote "$SERVER_CGROUP")/cpuset.mems
  echo $(yba_quote "$CLIENT_CPUSET_EXPECT") > $(yba_quote "$CLIENT_CGROUP")/cpuset.cpus
  echo $(yba_quote "$CLIENT_MEMS_EXPECT") > $(yba_quote "$CLIENT_CGROUP")/cpuset.mems
EOF
}

yba_cgroup_need_file() {
    local file=$1
    [ -e "$file" ] || {
        yba_cgroup_config_hint
        yba_die "missing cgroup file: $file"
    }
}

yba_configure_one_cpuset() {
    local cgroup=$1
    local cpus=$2
    local mems=$3
    [ -d "$cgroup" ] || {
        yba_cgroup_config_hint
        yba_die "missing cgroup: $cgroup"
    }
    if [ -n "$mems" ]; then
        yba_cgroup_need_file "$cgroup/cpuset.mems"
        yba_cgroup_write_file "$cgroup/cpuset.mems" "$mems" || {
            yba_cgroup_config_hint
            yba_die "cannot write $cgroup/cpuset.mems as $(id -un)"
        }
    fi
    if [ -n "$cpus" ]; then
        yba_cgroup_need_file "$cgroup/cpuset.cpus"
        yba_cgroup_write_file "$cgroup/cpuset.cpus" "$cpus" || {
            yba_cgroup_config_hint
            yba_die "cannot write $cgroup/cpuset.cpus as $(id -un)"
        }
    fi
}

yba_configure_cgroup_cpuset() {
    [ "$CGROUP_AUTO_CONFIG" = "1" ] || return 0
    [ -d "$CGROUP_ROOT" ] || {
        yba_cgroup_config_hint
        yba_die "missing CGROUP_ROOT: $CGROUP_ROOT"
    }
    if [ -f "$CGROUP_ROOT/cgroup.subtree_control" ] && grep -qw cpuset "$CGROUP_ROOT/cgroup.controllers" 2>/dev/null; then
        if ! grep -qw cpuset "$CGROUP_ROOT/cgroup.subtree_control" 2>/dev/null; then
            yba_cgroup_write_file "$CGROUP_ROOT/cgroup.subtree_control" "+cpuset" || {
                yba_cgroup_config_hint
                yba_die "cannot enable cpuset in $CGROUP_ROOT/cgroup.subtree_control as $(id -un)"
            }
        fi
    fi
    yba_configure_one_cpuset "$SERVER_CGROUP" "$SERVER_CPUSET_EXPECT" "$SERVER_MEMS_EXPECT"
    yba_configure_one_cpuset "$CLIENT_CGROUP" "$CLIENT_CPUSET_EXPECT" "$CLIENT_MEMS_EXPECT"
}

yba_configure_cgroup_cpuset_role() {
    [ "$CGROUP_AUTO_CONFIG" = "1" ] || return 0
    local role=$1
    [ -d "$CGROUP_ROOT" ] || {
        yba_cgroup_config_hint
        yba_die "missing CGROUP_ROOT: $CGROUP_ROOT"
    }
    if [ -f "$CGROUP_ROOT/cgroup.subtree_control" ] && grep -qw cpuset "$CGROUP_ROOT/cgroup.controllers" 2>/dev/null; then
        if ! grep -qw cpuset "$CGROUP_ROOT/cgroup.subtree_control" 2>/dev/null; then
            yba_cgroup_write_file "$CGROUP_ROOT/cgroup.subtree_control" "+cpuset" || {
                yba_cgroup_config_hint
                yba_die "cannot enable cpuset in $CGROUP_ROOT/cgroup.subtree_control as $(id -un)"
            }
        fi
    fi
    case "$role" in
        server)
            yba_configure_one_cpuset "$SERVER_CGROUP" "$SERVER_CPUSET_EXPECT" "$SERVER_MEMS_EXPECT"
            ;;
        client)
            yba_configure_one_cpuset "$CLIENT_CGROUP" "$CLIENT_CPUSET_EXPECT" "$CLIENT_MEMS_EXPECT"
            ;;
        both)
            yba_configure_one_cpuset "$SERVER_CGROUP" "$SERVER_CPUSET_EXPECT" "$SERVER_MEMS_EXPECT"
            yba_configure_one_cpuset "$CLIENT_CGROUP" "$CLIENT_CPUSET_EXPECT" "$CLIENT_MEMS_EXPECT"
            ;;
        *)
            yba_die "unknown cgroup role: $role"
            ;;
    esac
}

yba_preflight_one_cgroup() {
    local role=$1
    local cgroup cpus mems
    case "$role" in
        server)
            cgroup=$SERVER_CGROUP
            cpus=$SERVER_CPUSET_EXPECT
            mems=$SERVER_MEMS_EXPECT
            ;;
        client)
            cgroup=$CLIENT_CGROUP
            cpus=$CLIENT_CPUSET_EXPECT
            mems=$CLIENT_MEMS_EXPECT
            ;;
        *)
            yba_die "unknown cgroup role: $role"
            ;;
    esac
    [ -d "$cgroup" ] || yba_die "missing ${role^^}_CGROUP: $cgroup"
    if [ -n "$cpus" ]; then
        [ "$(yba_cgroup_value "$cgroup" cpuset.cpus)" = "$cpus" ] || yba_die "unexpected $role cpuset"
    fi
    if [ -n "$mems" ]; then
        [ "$(yba_cgroup_value "$cgroup" cpuset.mems)" = "$mems" ] || yba_die "unexpected $role mems"
    fi
    yba_smoke_test_cgroup_procs "$cgroup"
}

yba_preflight_cgroup_role() {
    [ "$ENABLE_CGROUP" = "1" ] || return 0
    local role=${1:-both}
    yba_configure_cgroup_cpuset_role "$role"
    case "$role" in
        server|client)
            yba_preflight_one_cgroup "$role"
            ;;
        both)
            yba_preflight_one_cgroup server
            yba_preflight_one_cgroup client
            ;;
        *)
            yba_die "unknown cgroup role: $role"
            ;;
    esac
}

yba_preflight_cgroup() {
    [ "$ENABLE_CGROUP" = "1" ] || return 0
    yba_preflight_cgroup_role both
}

yba_smoke_test_cgroup_procs() {
    [ "$CGROUP_PROCS_SMOKE_TEST" = "1" ] || return 0
    local cgroup=$1
    sleep 30 &
    local pid=$!
    if ! yba_cgroup_write_pid "$pid" "$cgroup"; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        yba_die "cgroup.procs smoke test failed for $cgroup"
    fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
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
