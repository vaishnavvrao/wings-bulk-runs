#!/bin/bash
# Summarise the AST queue: every field's state and chunk counts, plus live progress
# of the field that is running now.
# Usage: ast_report.sh

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
source $REPO/lib/common.sh

STATUS=$PIPE_DIR/ast_queue_status.tsv
[ -f $PIPE_DIR/AST_PAUSE ] && echo "*** AST_PAUSE is set: no new fields will launch ***"

declare -A STATE
[ -f $STATUS ] && while read -r run j t s rest; do STATE[$run]=$s; done < <(tail -n +2 $STATUS)

printf "%-18s %-7s %6s %7s %5s %9s\n" run state chunks outputs empty completed
for run in $(cut -f1 $PIPE_DIR/ast_pending.txt); do
    s=${STATE[$run]:-QUEUED}
    field=${run%r[0-9]*}
    proc=$(ls -d $PIPE_DIR/$run/data/$field/proc_* | head -1)
    logd=$(ls -d $PIPE_DIR/$run/data/$field/log_* | head -1)
    chunks=$(( ($(wc -l < $proc/$field.fakelist) + 99) / 100 ))
    if [ $s = QUEUED ]; then
        printf "%-18s %-7s %6d %7s %5s %9s\n" $run $s $chunks - - -
        continue
    fi
    out=$(find $proc -maxdepth 1 -name "$field.phot_*.fake" | wc -l)
    empty=$(find $proc -maxdepth 1 -name "$field.phot_*.fake" -size 0 | wc -l)
    done_=$(grep -l "Completed .* artificial stars" $logd/run_fakestars.py_j*.log 2>/dev/null | wc -l)
    printf "%-18s %-7s %6d %7d %5d %9d\n" $run $s $chunks $out $empty $done_
    if [ $s = ACTIVE ]; then
        echo "    jobs: $(squeue -h -u $USER -O "WorkDir:1000,State" | awk -v p=$PIPE_DIR/$run '$1==p {print $2}' | sort | uniq -c | xargs)"
        echo "    (while a field runs, 'empty' includes chunks still in progress)"
    fi
done
echo
tail -n +2 $STATUS 2>/dev/null | cut -f4 | sort | uniq -c
