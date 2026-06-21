#!/usr/bin/env bash

yba_start_metrics() {
    local dir=$1
    mkdir -p "$dir/metrics"
    if [ "$ENABLE_NODE_CPU_SAMPLER" = "1" ] && command -v python3 >/dev/null; then
        python3 "$YBA_ROOT/tools/sample-node-cpu.py" --out "$dir/metrics/cpu-node-samples.csv" --interval 1 --max-seconds "$RUN_SECONDS" \
            > "$dir/metrics/cpu-sampler.log" 2>&1 &
        echo $! > "$dir/metrics/cpu-sampler.pid"
        disown "$!" 2>/dev/null || true
    fi
    if [ "$ENABLE_VMSTAT" = "1" ] && command -v vmstat >/dev/null; then
        timeout "$RUN_SECONDS" vmstat 1 > "$dir/metrics/vmstat.log" 2>&1 &
        echo $! > "$dir/metrics/vmstat.pid"
        disown "$!" 2>/dev/null || true
    fi
    if [ "$ENABLE_NUMASTAT" = "1" ] && command -v numastat >/dev/null; then
        local pid
        pid=$(bash -lc "$SERVER_PID_COMMAND" 2>/dev/null | head -1 || true)
        if [ -n "$pid" ]; then
            numastat -p "$pid" > "$dir/metrics/numastat-before.txt" 2>&1 || true
        fi
    fi
}

yba_stop_metrics() {
    local dir=$1
    local pid_file pid
    for pid_file in "$dir"/metrics/*.pid; do
        [ -f "$pid_file" ] || continue
        pid=$(cat "$pid_file" 2>/dev/null || true)
        [ -n "$pid" ] || continue
        kill -INT "$pid" 2>/dev/null || true
        sleep 1
        kill -TERM "$pid" 2>/dev/null || true
    done
    if [ "$ENABLE_NUMASTAT" = "1" ] && command -v numastat >/dev/null; then
        local pid
        pid=$(bash -lc "$SERVER_PID_COMMAND" 2>/dev/null | head -1 || true)
        if [ -n "$pid" ]; then
            numastat -p "$pid" > "$dir/metrics/numastat-after.txt" 2>&1 || true
        fi
    fi
    ps -eo pid,ppid,psr,pcpu,pmem,comm,args --sort=-pcpu | head -120 > "$dir/metrics/ps-top.log" 2>&1 || true
}
