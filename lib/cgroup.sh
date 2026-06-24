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

yba_cpu_in_list() {
    local cpu=$1
    local list=$2
    local part start end
    IFS=',' read -ra parts <<< "$list"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        if [[ "$part" == *-* ]]; then
            start=${part%-*}
            end=${part#*-}
            if [ "$cpu" -ge "$start" ] 2>/dev/null && [ "$cpu" -le "$end" ] 2>/dev/null; then
                return 0
            fi
        elif [ "$cpu" = "$part" ]; then
            return 0
        fi
    done
    return 1
}

yba_thread_cluster_rules_file() {
    local dir=$1
    mkdir -p "$dir/thread-cluster"
    local file="$dir/thread-cluster/rules.tsv"
    : > "$file"
    local rule name rest regex cpus
    for rule in $THREAD_CLUSTER_RULES; do
        name=${rule%%:*}
        rest=${rule#*:}
        regex=${rest%:*}
        cpus=${rest##*:}
        [ -n "$name" ] && [ -n "$regex" ] && [ -n "$cpus" ] || yba_die "bad THREAD_CLUSTER_RULES item: $rule"
        printf '%s\t%s\t%s\n' "$name" "$regex" "$cpus" >> "$file"
    done
    if [ -n "$THREAD_CLUSTER_DEFAULT_CPUS" ]; then
        printf '%s\t%s\t%s\n' "$THREAD_CLUSTER_DEFAULT_NAME" ".*" "$THREAD_CLUSTER_DEFAULT_CPUS" >> "$file"
    fi
    printf '%s\n' "$file"
}

yba_snapshot_thread_cluster_matches() {
    local dir=$1
    local phase=$2
    [ "$ENABLE_THREAD_CLUSTER" = "1" ] || return 0
    [ -n "$THREAD_CLUSTER_RULES$THREAD_CLUSTER_DEFAULT_CPUS" ] || return 0
    mkdir -p "$dir/thread-cluster"
    local rules_file="$dir/thread-cluster/rules.tsv"
    [ -f "$rules_file" ] || rules_file=$(yba_thread_cluster_rules_file "$dir")
    local out="$dir/thread-cluster/${phase}-matches.csv"
    echo "phase,rule,pid,tid,comm,target_cpus,psr,affinity_cpus,on_target_cpu" > "$out"
    local actions_file="$dir/thread-cluster/actions.csv"
    local pid rule regex cpus tid comm psr on_target pid_actions pid_threads
    if [ -f "$actions_file" ]; then
        cut -d, -f2 "$actions_file" | tail -n +2 | sort -u | while read -r pid; do
            [ -n "$pid" ] || continue
            pid_actions=$(mktemp)
            pid_threads=$(mktemp)
            awk -F, -v pid="$pid" 'NR > 1 && $2 == pid {print $0}' "$actions_file" > "$pid_actions"
            ps -T -p "$pid" -o tid=,comm=,psr= 2>/dev/null > "$pid_threads" || true
            awk -F, -v phase="$phase" -v threads="$pid_threads" '
                BEGIN {
                    while ((getline line < threads) > 0) {
                        gsub(/^[[:space:]]+/, "", line)
                        split(line, fields, /[[:space:]]+/)
                        tid = fields[1]
                        psr[tid] = fields[length(fields)]
                        name = fields[2]
                        for (idx = 3; idx < length(fields); idx++) {
                            name = name " " fields[idx]
                        }
                        comm[tid] = name
                    }
                }
                {
                    rule=$1; pid=$2; tid=$3; target=$5
                    if (!(tid in psr)) {
                        next
                    }
                    affinity = affinity_list(tid)
                    on_target = affinity_nonempty_subset(affinity, target)
                    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s\n", phase, rule, pid, tid, comm[tid], target, psr[tid], affinity, on_target
                }
                function affinity_list(tid, cmd, line, n, parts) {
                    cmd = "taskset -pc " tid " 2>/dev/null"
                    line = ""
                    while ((cmd | getline line) > 0) {}
                    close(cmd)
                    n = split(line, parts, ":")
                    if (n < 2) {
                        return ""
                    }
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[2])
                    return parts[2]
                }
                function cpu_in_list(cpu, list, parts, n, i, bounds) {
                    n = split(list, parts, ",")
                    for (i = 1; i <= n; i++) {
                        if (parts[i] ~ /-/) {
                            split(parts[i], bounds, "-")
                            if (cpu >= bounds[1] && cpu <= bounds[2]) {
                                return 1
                            }
                        } else if (cpu == parts[i]) {
                            return 1
                        }
                    }
                    return 0
                }
                function affinity_nonempty_subset(affinity, target, parts, n, i, bounds, cpu) {
                    if (affinity == "") {
                        return cpu_in_list(psr[tid], target)
                    }
                    n = split(affinity, parts, ",")
                    for (i = 1; i <= n; i++) {
                        if (parts[i] ~ /-/) {
                            split(parts[i], bounds, "-")
                            for (cpu = bounds[1]; cpu <= bounds[2]; cpu++) {
                                if (!cpu_in_list(cpu, target)) {
                                    return 0
                                }
                            }
                        } else if (!cpu_in_list(parts[i], target)) {
                            return 0
                        }
                    }
                    return 1
                }
            ' "$pid_actions" >> "$out"
            rm -f "$pid_actions" "$pid_threads"
        done
        return 0
    fi
    while IFS=$'\t' read -r rule regex cpus; do
        [ -n "$rule" ] || continue
        for pid in $(bash -lc "$SERVER_PID_COMMAND" 2>/dev/null || true); do
            ps -T -p "$pid" -o tid=,comm=,psr= 2>/dev/null | awk -v re="$regex" '$2 ~ re {print $1, $2, $3}' |
                while read -r tid comm psr; do
                    [ -n "$tid" ] || continue
                    on_target=0
                    if yba_cpu_in_list "$psr" "$cpus"; then
                        on_target=1
                    fi
                    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$phase" "$rule" "$pid" "$tid" "$comm" "$cpus" "$psr" "" "$on_target" >> "$out"
                done
        done
    done < "$rules_file"
}

yba_thread_cluster_summarize_rule() {
    local rule=$1
    local before_file=$2
    local after_file=$3
    awk -F, -v rule="$rule" '
        FNR == NR {
            if (NR > 1 && $2 == rule) {
                before[$4] = 1
                before_count++
            }
            next
        }
        FNR > 1 && $2 == rule {
            after[$4] = 1
            after_count++
            if ($9 == "1") {
                on_target++
            }
        }
        END {
            for (tid in after) {
                if (!(tid in before)) {
                    new_count++
                }
            }
            for (tid in before) {
                if (!(tid in after)) {
                    missing_count++
                }
            }
            hit_ratio = after_count ? on_target / after_count : 0
            state = (new_count == 0 && missing_count == 0) ? "stable" : "changed"
            printf "%s,%d,%d,%d,%d,%d,%.6f,%s\n", rule, before_count, after_count, on_target, new_count, missing_count, hit_ratio, state
        }
    ' "$before_file" "$after_file"
}

yba_thread_cluster_rule_is_strict() {
    local rule=$1
    local item strict_rules
    if [ -z "$THREAD_CLUSTER_STRICT_RULES" ]; then
        return 0
    fi
    strict_rules=${THREAD_CLUSTER_STRICT_RULES//,/ }
    for item in $strict_rules; do
        if [ "$item" = "$rule" ]; then
            return 0
        fi
    done
    return 1
}

yba_thread_cluster_taskset() {
    local cpus=$1
    local tid=$2
    if [ "${THREAD_CLUSTER_TASKSET_WITH_SUDO:-0}" = "1" ]; then
        if [ -n "${SUDO_ASKPASS:-}" ]; then
            SUDO_ASKPASS="$SUDO_ASKPASS" sudo -A taskset -pc "$cpus" "$tid"
        else
            sudo taskset -pc "$cpus" "$tid"
        fi
    else
        taskset -pc "$cpus" "$tid"
    fi
}

yba_check_thread_cluster_static() {
    [ "$ENABLE_THREAD_CLUSTER" = "1" ] || return 0
    [ -n "$THREAD_CLUSTER_RULES" ] || return 0
    local dir=$1
    mkdir -p "$dir/thread-cluster"
    local rules_file="$dir/thread-cluster/rules.tsv"
    [ -f "$rules_file" ] || rules_file=$(yba_thread_cluster_rules_file "$dir")
    yba_snapshot_thread_cluster_matches "$dir" after-ycsb
    local before_file="$dir/thread-cluster/after-bind-matches.csv"
    local after_file="$dir/thread-cluster/after-ycsb-matches.csv"
    local summary="$dir/thread-cluster/summary.csv"
    echo "rule,bound_threads,after_ycsb_threads,on_target_cpu_threads,new_threads,missing_threads,hit_ratio,thread_set_state" > "$summary"
    local rule regex cpus line failed=0 action_rule rule_failed
    if [ -f "$dir/thread-cluster/actions.csv" ]; then
        while read -r action_rule; do
            [ -n "$action_rule" ] || continue
            if yba_thread_cluster_rule_is_strict "$action_rule"; then
                failed=1
            fi
        done < <(awk -F, 'NR > 1 && $6 != "bound" {print $1}' "$dir/thread-cluster/actions.csv" | sort -u)
    fi
    while IFS=$'\t' read -r rule regex cpus; do
        [ -n "$rule" ] || continue
        line=$(yba_thread_cluster_summarize_rule "$rule" "$before_file" "$after_file")
        echo "$line" >> "$summary"
        rule_failed=0
        IFS=, read -r _ bound after on_target new_count missing_count hit_ratio state <<< "$line"
        if awk -v hit="$hit_ratio" -v min="$THREAD_CLUSTER_MIN_HIT_RATIO" 'BEGIN { exit !(hit < min) }'; then
            rule_failed=1
        fi
        if [ "$THREAD_CLUSTER_REQUIRE_STABLE" = "1" ] && [ "$state" != "stable" ]; then
            rule_failed=1
        fi
        if [ "$bound" = "0" ]; then
            rule_failed=1
        fi
        if [ "$rule_failed" = "1" ] && yba_thread_cluster_rule_is_strict "$rule"; then
            failed=1
        fi
    done < "$rules_file"
    if [ "$THREAD_CLUSTER_STRICT" = "1" ] && [ "$failed" = "1" ]; then
        yba_die "thread cluster verification failed; see $summary"
    fi
}

yba_apply_thread_cluster() {
    [ "$ENABLE_THREAD_CLUSTER" = "1" ] || return 0
    [ -n "$THREAD_CLUSTER_RULES$THREAD_CLUSTER_DEFAULT_CPUS" ] || return 0
    local dir=$1
    mkdir -p "$dir/thread-cluster"
    local rules_file
    rules_file=$(yba_thread_cluster_rules_file "$dir")
    echo "rule,pid,tid,comm,target_cpus,status" > "$dir/thread-cluster/actions.csv"
    local pid name regex cpus tid comm status default_name matched_file
    default_name=$THREAD_CLUSTER_DEFAULT_NAME
    matched_file="$dir/thread-cluster/explicit-matched-tids.txt"
    : > "$matched_file"
    for pid in $(bash -lc "$SERVER_PID_COMMAND" 2>/dev/null || true); do
        ps -T -p "$pid" -o tid=,comm= > "$dir/thread-cluster/before-${pid}.txt" || true
        while IFS=$'\t' read -r name regex cpus; do
            ps -T -p "$pid" -o tid=,comm= | awk -v re="$regex" '$2 ~ re {print $1, $2}' |
                while read -r tid comm; do
                    [ -n "$tid" ] || continue
                    if [ -n "$THREAD_CLUSTER_DEFAULT_CPUS" ] && [ "$name" = "$default_name" ] && grep -qx "$pid:$tid" "$matched_file"; then
                        continue
                    fi
                    echo "$name pid=$pid tid=$tid cpus=$cpus" >> "$dir/thread-cluster/actions.log"
                    status=bound
                    yba_thread_cluster_taskset "$cpus" "$tid" >> "$dir/thread-cluster/actions.log" 2>&1 || status=failed
                    printf '%s,%s,%s,%s,%s,%s\n' "$name" "$pid" "$tid" "$comm" "$cpus" "$status" >> "$dir/thread-cluster/actions.csv"
                    if [ "$name" != "$default_name" ]; then
                        printf '%s:%s\n' "$pid" "$tid" >> "$matched_file"
                    fi
                done
        done < "$rules_file"
        ps -T -p "$pid" -o tid=,comm=,psr= > "$dir/thread-cluster/after-${pid}.txt" || true
    done
    yba_snapshot_thread_cluster_matches "$dir" after-bind
}
