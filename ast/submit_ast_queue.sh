#!/bin/bash
# Start the AST queue (ast_queue.sh) as a 7-day, 1-CPU SLURM job.
# Its log is $PIPE_DIR/ast_queue_<jobid>.log. Resubmit to continue after the 7 days run out.

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
source $REPO/lib/common.sh

if squeue -h -u $USER -n astqueue | grep -q .; then
    echo "An AST queue job is already running:" >&2
    squeue -u $USER -n astqueue >&2
    exit 1
fi
submit_queue $REPO/ast/ast_queue.sh astqueue ast_queue
