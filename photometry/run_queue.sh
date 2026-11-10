#!/bin/bash
# Throttled photometry launcher: keeps at most MAXACTIVE runs from pending_fields.txt in flight.
# Start it with submit_queue.sh (runs as a SLURM job); running it in a terminal works too.
# All files below are in $PIPE_DIR:
#   pending_fields.txt  run directories to launch, in order
#   queue.conf          optional MAXACTIVE=<n>, re-read every loop (overrides config.sh)
#   PAUSE               if present, no new launches (running fields continue)
#   queue_status.tsv    run  launch_epoch  state  end_epoch   (state: ACTIVE/DONE/STALLED)
# A run is DONE once its *_gst_spatial.png exists (the last pipeline step), and STALLED
# if it has no SLURM jobs and no final output. A STALLED run is never relaunched:
# a rerun needs a new <field>rN directory.
# Safe to restart: state is reloaded from queue_status.tsv.

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
source $REPO/lib/common.sh

QUEUE=$PIPE_DIR/pending_fields.txt
STATUS=$PIPE_DIR/queue_status.tsv
CONF=$PIPE_DIR/queue.conf
INTERVAL=600   # seconds between checks
GRACE=900      # seconds after launch before a field with no jobs counts as stalled

declare -A LAUNCH STATE END
ORDER=()
if [ -f $STATUS ]; then
    while read -r run t s e; do
        [ "$run" = run ] && continue
        LAUNCH[$run]=$t; STATE[$run]=$s; END[$run]=$e; ORDER+=($run)
    done < $STATUS
fi

write_status() {
    { printf "run\tlaunch_epoch\tstate\tend_epoch\n"
      for run in "${ORDER[@]}"; do
          printf "%s\t%s\t%s\t%s\n" $run ${LAUNCH[$run]} ${STATE[$run]} ${END[$run]:--}
      done; } > $STATUS.tmp && mv $STATUS.tmp $STATUS
}

is_done() {
    local field=${1%r[0-9]*}
    ls $PIPE_DIR/$1/data/$field/proc_*/${field}_*gst_spatial.png > /dev/null 2>&1
}

DEFAULT_MAXACTIVE=$MAXACTIVE
while true; do
    MAXACTIVE=$DEFAULT_MAXACTIVE
    [ -f $CONF ] && source $CONF

    # skip the cycle if squeue fails, otherwise every field would look stalled
    if ! WORKDIRS=$(squeue -h -u $USER -O "WorkDir:1000" | sed 's/ *$//'); then
        log "squeue failed; retrying next cycle"
        sleep $INTERVAL; continue
    fi

    now=$(date +%s)
    nactive=0
    for run in "${ORDER[@]}"; do
        [ "${STATE[$run]}" = DONE ] && continue
        if is_done $run; then
            STATE[$run]=DONE; END[$run]=$now; log "$run DONE"
        elif echo "$WORKDIRS" | grep -qx "$PIPE_DIR/$run" || [ $((now - ${LAUNCH[$run]})) -lt $GRACE ]; then
            [ "${STATE[$run]}" != ACTIVE ] && log "$run ACTIVE again"
            STATE[$run]=ACTIVE; END[$run]=-
            nactive=$((nactive+1))
        elif [ "${STATE[$run]}" = ACTIVE ]; then
            STATE[$run]=STALLED; END[$run]=$now; log "$run STALLED (no jobs, no output)"
        fi
    done

    remaining=0
    for run in $(grep -v '^\s*$' $QUEUE); do
        [ -n "${STATE[$run]}" ] && continue
        remaining=$((remaining+1))
        [ -f $PIPE_DIR/PAUSE ] && continue
        [ $nactive -ge $MAXACTIVE ] && continue
        ensure_max_connections || continue
        log "launching $run"
        (cd $PIPE_DIR/$run && wingspipe run) >> $PIPE_DIR/$run/run.log 2>&1
        LAUNCH[$run]=$(date +%s); STATE[$run]=ACTIVE; END[$run]=-; ORDER+=($run)
        nactive=$((nactive+1)); remaining=$((remaining-1))
    done

    write_status
    if [ $remaining -eq 0 ] && [ $nactive -eq 0 ]; then
        log "queue empty and nothing active; exiting"
        break
    fi
    sleep $INTERVAL
done
