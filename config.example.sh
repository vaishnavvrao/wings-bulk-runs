# Site settings shared by every script in this repo.
# Copy to config.sh (which git ignores) and edit:   cp config.example.sh config.sh
# The values below are the ones used for GO-8277 on Great Lakes.

# --- Where things live -------------------------------------------------------
# Run directories (<field>rN/), the queue lists, status files and queue logs all go here.
PIPE_DIR=/nfs/turbo/lsa-ericbell1/vvrao/pipelines/GO-8277

# Input images: one directory per visit, <GAL>_vNN/{NIRCam,NIRISS}/crf/
IMG_DIR=/nfs/turbo/lsa-ericbell1/vvrao/data/GO-8277/images_reprocessed

# wingspipe task scripts that `wingspipe init` copies into each run directory
BUILD_DIR=/nfs/turbo/lsa-ericbell1/vvrao/phat_pypipeline_repo/build/

# Pipeline configs
CONF_NIRCAM=$PIPE_DIR/jwst2cam3.1.conf
CONF_NIRISS=$PIPE_DIR/jwstnis3.1.conf

# --- Environment and SLURM ---------------------------------------------------
# Command that makes `wingspipe` and python available
ENV_SETUP='source ~/.bashrc && micromamba activate stenv-py313'
SLURM_ACCOUNT=ericbell0
SLURM_PARTITION=standard

# --- Photometry queue --------------------------------------------------------
# Default number of fields in flight. Can be changed while the queue runs by
# writing MAXACTIVE=<n> to $PIPE_DIR/queue.conf.
MAXACTIVE=4

# --- ASTs --------------------------------------------------------------------
# AST input lists: $AST_INPUT_DIR/<field>/<field>_inputAST_final.txt (first row is a header)
AST_INPUT_DIR=/nfs/turbo/lsa-ericbell1/vvrao/working/GO-8277/beast-workflow
# DOLPHOT binary the AST step runs. dolphot2.1 is used because dolphot3.x honours
# MaxThreads and oversubscribes the node when 10 chunks share it.
DOLPHOT_AST_BIN=/nfs/turbo/lsa-ericbell1/vvrao/software/dolphot2.1/bin/dolphot
# Memory per AST job (10 chunks of 100 stars share one node).
AST_MEM_NIRCAM=50G
AST_MEM_NIRCAM_DENSE=80G      # NIRCam fields whose real-star .phot has more than...
AST_DENSE_NSTARS=250000       # ...this many stars
AST_MEM_NIRISS=80G

# --- wpipe SQL server --------------------------------------------------------
# The server's max_connections drops back to 151 whenever it restarts or moves.
# Before every launch the queues raise it to SQL_MAX_CONNECTIONS; with fewer,
# jobs die with "Too many connections" when they import wpipe.
SQL_SERVER_FILE=/nfs/turbo/lsa-ericbell1/asmerci/server.address   # holds the current IP
SQL_PORT=8030
SQL_USER=CHANGE_ME
SQL_PASS=CHANGE_ME
SQL_MAX_CONNECTIONS=1500
