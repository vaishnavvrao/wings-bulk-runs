#!/bin/bash
# Start the photometry queue (run_queue.sh) as a 7-day, 1-CPU SLURM job.
# Its log is $PIPE_DIR/run_queue_<jobid>.log. Resubmit to continue after the 7 days run out.

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
source $REPO/lib/common.sh

if squeue -h -u $USER -n photqueue | grep -q .; then
    echo "A photometry queue job is already running:" >&2
    squeue -u $USER -n photqueue >&2
    exit 1
fi
submit_queue $REPO/photometry/run_queue.sh photqueue run_queue
