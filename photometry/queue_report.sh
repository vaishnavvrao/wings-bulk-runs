#!/bin/bash
# Summarise the photometry queue: state, SLURM jobs in flight, last task submitted,
# and minutes since that submission (a large value on an ACTIVE run = possible hang).
# Usage: queue_report.sh [STATE]     e.g. queue_report.sh STALLED

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
source $REPO/lib/common.sh

STATUS=$PIPE_DIR/queue_status.tsv
WORKDIRS=$(squeue -h -u $USER -O "WorkDir:1000" | sed 's/ *$//')
now=$(date +%s)

declare -A STATE
[ -f $STATUS ] && while read -r run t s e; do STATE[$run]=$s; done < <(tail -n +2 $STATUS)

printf "%-18s %-8s %5s  %-20s %8s\n" run state jobs last_task idle_min
for run in $(grep -v '^\s*$' $PIPE_DIR/pending_fields.txt); do
    s=${STATE[$run]:-QUEUED}
    [ -n "$1" ] && [ "$1" != "$s" ] && continue
    jobs=$(echo "$WORKDIRS" | grep -cx "$PIPE_DIR/$run")
    last=$(ls -t $PIPE_DIR/$run/config/*.list 2>/dev/null | head -1)
    if [ -n "$last" ]; then
        task=$(grep -o 'build/[A-Za-z0-9_]*\.py' $last | head -1 | sed 's#build/##')
        idle=$(( (now - $(stat -c %Y $last)) / 60 ))
    else
        task=-; idle=-
    fi
    printf "%-18s %-8s %5s  %-20s %8s\n" $run $s $jobs $task $idle
done
echo
cut -f3 $STATUS 2>/dev/null | tail -n +2 | sort | uniq -c
