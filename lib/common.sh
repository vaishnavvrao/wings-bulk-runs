# Shared helpers. Source this from a script after setting REPO to the repo root.

if [ ! -f $REPO/config.sh ]; then
    echo "No $REPO/config.sh. Create it with: cp $REPO/config.example.sh $REPO/config.sh" >&2
    exit 1
fi
source $REPO/config.sh

log() { echo "[$(date '+%F %T')] $*"; }

# Raise max_connections on the wpipe SQL server to SQL_MAX_CONNECTIONS if it is lower.
# Returns 1 (and logs why) if the server can't be reached or the change fails,
# so callers can hold off launching.
ensure_max_connections() {
    local host=$(tr -d '[:space:]' < $SQL_SERVER_FILE)
    local sql="mysql -h $host -P $SQL_PORT -u $SQL_USER -p$SQL_PASS -N -B"
    local cur=$($sql -e "SELECT @@GLOBAL.max_connections" 2>/dev/null)
    [ -n "$cur" ] || { log "SQL server $host not reachable"; return 1; }
    if [ $cur -lt $SQL_MAX_CONNECTIONS ]; then
        $sql -e "SET GLOBAL max_connections = $SQL_MAX_CONNECTIONS" 2>/dev/null \
            || { log "SET max_connections failed on $host"; return 1; }
        log "max_connections on $host raised $cur -> $($sql -e "SELECT @@GLOBAL.max_connections" 2>/dev/null)"
    fi
    return 0
}

# Submit a queue script as a long-running 1-CPU SLURM job. Its log goes to $PIPE_DIR.
#   submit_queue <script> <job name> <log prefix>
submit_queue() {
    sbatch --job-name=$2 --account=$SLURM_ACCOUNT --partition=$SLURM_PARTITION \
        --nodes=1 --ntasks-per-node=1 --cpus-per-task=1 --mem=2G --time=7-00:00:00 \
        --chdir=$PIPE_DIR --output=$PIPE_DIR/$3_%j.log <<EOF
#!/bin/bash
$ENV_SETUP || exit 1
$1
EOF
}
