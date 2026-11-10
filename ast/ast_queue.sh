#!/bin/bash
# Sequential AST launcher: runs one field's ASTs at a time, because a single field's
# chunk jobs fill the group allocation. Start it with submit_ast_queue.sh.
# All files below are in $PIPE_DIR:
#   ast_pending.txt       run <tab> launch script, in order (written by ast_prep.sh)
#   AST_PAUSE             if present, no new launches (a running field continues)
#   ast_queue_status.tsv  run jobid launch_epoch state end_epoch chunks outputs empty completed
#                         (state: ACTIVE/DONE)
# Before each launch, max_connections on the wpipe SQL server is raised if needed.
# A field is DONE after two consecutive checks with no SLURM jobs, at least GRACE after launch.
# Failed chunks (empty or missing outputs) are only counted in the status file. The queue
# pauses itself only on a failure that would hit every field: a "Cannot open" error in a
# run_fakestars log (e.g. a missing PSF file), or a field that finishes with no output.
# Safe to restart: state is reloaded from ast_queue_status.tsv.

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
source $REPO/lib/common.sh

QUEUE=$PIPE_DIR/ast_pending.txt
STATUS=$PIPE_DIR/ast_queue_status.tsv
PAUSE_FILE=$PIPE_DIR/AST_PAUSE
INTERVAL=600   # seconds between checks
GRACE=1800     # seconds after launch before a field with no jobs can count as done

declare -A JOBID LAUNCH STATE END CHUNKS OUTPUTS EMPTY COMPLETED IDLE
ORDER=()
if [ -f $STATUS ]; then
    while read -r run j t s e c o m d; do
        [ "$run" = run ] && continue
        JOBID[$run]=$j; LAUNCH[$run]=$t; STATE[$run]=$s; END[$run]=$e
        CHUNKS[$run]=$c; OUTPUTS[$run]=$o; EMPTY[$run]=$m; COMPLETED[$run]=$d
        ORDER+=($run)
    done < $STATUS
fi

write_status() {
    { printf "run\tjobid\tlaunch_epoch\tstate\tend_epoch\tchunks\toutputs\tempty\tcompleted\n"
      for run in "${ORDER[@]}"; do
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" $run ${JOBID[$run]} ${LAUNCH[$run]} \
              ${STATE[$run]} ${END[$run]:--} ${CHUNKS[$run]:--} ${OUTPUTS[$run]:--} \
              ${EMPTY[$run]:--} ${COMPLETED[$run]:--}
      done; } > $STATUS.tmp && mv $STATUS.tmp $STATUS
}

field_dirs() {  # sets FIELD PROC LOGD for run $1
    FIELD=${1%r[0-9]*}
    PROC=$(ls -d $PIPE_DIR/$1/data/$FIELD/proc_* | head -1)
    LOGD=$(ls -d $PIPE_DIR/$1/data/$FIELD/log_* | head -1)
}

count_results() {
    field_dirs $1
    local nstars=$(wc -l < $PROC/$FIELD.fakelist)
    CHUNKS[$1]=$(( (nstars + 99) / 100 ))
    OUTPUTS[$1]=$(find $PROC -maxdepth 1 -name "$FIELD.phot_*.fake" | wc -l)
    EMPTY[$1]=$(find $PROC -maxdepth 1 -name "$FIELD.phot_*.fake" -size 0 | wc -l)
    COMPLETED[$1]=$(grep -l "Completed .* artificial stars" $LOGD/run_fakestars.py_j*.log 2>/dev/null | wc -l)
}

pause() { touch $PAUSE_FILE; log "PAUSED: $*"; }

while true; do
    # skip the cycle if squeue fails, otherwise the active field would look finished
    if ! WORKDIRS=$(squeue -h -u $USER -O "WorkDir:1000" | sed 's/ *$//'); then
        log "squeue failed; retrying next cycle"
        sleep $INTERVAL; continue
    fi

    now=$(date +%s)
    active=
    for run in "${ORDER[@]}"; do
        [ "${STATE[$run]}" = ACTIVE ] || continue
        field_dirs $run
        if [ ! -f $PAUSE_FILE ] && grep -l "Cannot open" $LOGD/run_fakestars.py_j*.log > /dev/null 2>&1; then
            pause "$run: 'Cannot open' in a run_fakestars log (missing PSF or input?)"
        fi
        njobs=$(echo "$WORKDIRS" | grep -cx "$PIPE_DIR/$run")
        if [ $njobs -gt 0 ] || [ $((now - ${LAUNCH[$run]})) -lt $GRACE ]; then
            IDLE[$run]=0; active=$run
        elif [ "${IDLE[$run]:-0}" -lt 1 ]; then
            IDLE[$run]=1; active=$run   # first empty check; confirm on the next one
        else
            count_results $run
            STATE[$run]=DONE; END[$run]=$now
            log "$run DONE: chunks ${CHUNKS[$run]} outputs ${OUTPUTS[$run]} empty ${EMPTY[$run]} completed ${COMPLETED[$run]}"
            [ $(( ${OUTPUTS[$run]} - ${EMPTY[$run]} )) -eq 0 ] && pause "$run finished with no non-empty outputs"
        fi
    done

    remaining=0
    for run in $(cut -f1 $QUEUE); do
        [ -n "${STATE[$run]}" ] || remaining=$((remaining+1))
    done

    if [ -z "$active" ] && [ $remaining -gt 0 ] && [ ! -f $PAUSE_FILE ]; then
        for run in $(cut -f1 $QUEUE); do
            [ -n "${STATE[$run]}" ] && continue
            slurm=$(awk -v r=$run '$1==r {print $2}' $QUEUE)
            ensure_max_connections || break
            out=$(cd $PIPE_DIR/$run && sbatch $slurm 2>&1)
            jid=$(echo "$out" | awk '/Submitted batch job/ {print $4}')
            if [ -z "$jid" ]; then log "sbatch failed for $run: $out"; break; fi
            log "launched $run (job $jid, $slurm)"
            JOBID[$run]=$jid; LAUNCH[$run]=$(date +%s); STATE[$run]=ACTIVE; END[$run]=-
            IDLE[$run]=0; ORDER+=($run); active=$run; remaining=$((remaining-1))
            break
        done
    fi

    write_status
    if [ $remaining -eq 0 ] && [ -z "$active" ]; then
        log "queue empty and nothing active; exiting"
        break
    fi
    sleep $INTERVAL
done
