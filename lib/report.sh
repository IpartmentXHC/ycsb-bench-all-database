#!/usr/bin/env bash

yba_summarize() {
    local dir=$1
    python3 "$YBA_ROOT/tools/summarize-ycsb.py" --experiment-dir "$dir"
}
