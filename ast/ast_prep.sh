#!/bin/bash
# Prepare finished photometry runs for ASTs. For each run directory listed in the fields file:
#   1. copy $AST_INPUT_DIR/<field>/<field>_inputAST_final.txt, minus its header row,
#      to proc_*/<field>.fakelist (never overwrites an existing .fakelist)
#   2. build/split_fakestars.py: set the job memory (see config.sh), check that
#      starsper = 100 and both walltimes are 6:00:00
#   3. build/run_fakestars.py: point DOLPHOT at $DOLPHOT_AST_BIN
#   4. append "run <tab> launch script" to $PIPE_DIR/ast_pending.txt. The launch script is
#      the run's earliest .slurm whose .list runs split_fakestars.py (it ran during the
#      photometry and stopped because there was no .fakelist yet).
# Never submits anything.
# Usage: ast_prep.sh [--dry-run] <fields file: one run directory name per line>

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
source $REPO/lib/common.sh

DRY=0
[ "$1" = --dry-run ] && { DRY=1; shift; }
FIELDS=$1
[ -f "$FIELDS" ] || { echo "Usage: $0 [--dry-run] <fields file>" >&2; exit 1; }
PENDING=$PIPE_DIR/ast_pending.txt

fail() { echo "FAIL $run: $*"; nfail=$((nfail+1)); }

nfail=0; nok=0
printf "%-18s %8s %7s %6s %4s %s\n" run nstars rows chunks mem slurm
for run in $(grep -v '^\s*$' $FIELDS); do
    field=${run%r[0-9]*}
    inp=$AST_INPUT_DIR/$field/${field}_inputAST_final.txt
    proc=$(ls -d $PIPE_DIR/$run/data/$field/proc_* 2>/dev/null | head -1)
    S=$PIPE_DIR/$run/build/split_fakestars.py
    F=$PIPE_DIR/$run/build/run_fakestars.py
    [ -f $inp ] || { fail "no input $inp"; continue; }
    [ -d "$proc" ] || { fail "no proc directory"; continue; }
    [ -s $proc/$field.phot ] || { fail "no .phot (photometry not finished?)"; continue; }
    grep -qx "$run.*" $PENDING 2>/dev/null && { fail "already in $PENDING"; continue; }

    # memory: NIRISS fixed; NIRCam depends on the number of real stars
    nstars=$(wc -l < $proc/$field.phot)
    case $field in
        *_nis_*) mem=$AST_MEM_NIRISS; ncol=6 ;;
        *)       ncol=7
                 if [ $nstars -gt $AST_DENSE_NSTARS ]; then mem=$AST_MEM_NIRCAM_DENSE; else mem=$AST_MEM_NIRCAM; fi ;;
    esac

    # launch script
    lst=$(ls -tr $(grep -l "split_fakestars.py" $PIPE_DIR/$run/config/*.list 2>/dev/null) 2>/dev/null | head -1)
    sl=${lst%.list}.slurm
    [ -n "$lst" ] && [ -f "$sl" ] || { fail "no split_fakestars .slurm in config/"; continue; }

    # checks that don't change anything
    fl=$proc/$field.fakelist
    [ -e $fl ] && { fail "$fl exists, not overwriting"; continue; }
    nin=$(($(wc -l < $inp) - 1))
    badcols=$(tail -n +2 $inp | awk -v n=$ncol 'NF!=n' | wc -l)
    [ $badcols -eq 0 ] || { fail "$badcols input rows without $ncol columns"; continue; }
    grep -q "starsper = 100.0" $S || { fail "starsper != 100 in $S"; continue; }
    [ $(grep -c "'walltime': \"6:00:00\"" $S) -eq 2 ] || { fail "walltimes not 6:00:00 in $S"; continue; }

    printf "%-18s %8d %7d %6d %4s %s\n" $run $nstars $nin $(( (nin + 99) / 100 )) $mem $(basename $sl)
    [ $DRY -eq 1 ] && continue

    # 1. fakelist
    tail -n +2 $inp > $fl
    [ $(wc -l < $fl) -eq $nin ] || { fail "fakelist has $(wc -l < $fl) rows, expected $nin"; continue; }

    # 2. memory
    sed -i -E "s/'memory': \"[0-9]+G\"/'memory': \"$mem\"/" $S
    grep -q "'memory': \"$mem\"" $S || { fail "could not set memory in $S"; continue; }

    # 3. DOLPHOT binary (the original line reads the path from the pipeline database)
    sed -i -E "s#my_config.parameters\[\"dolphot_path\"\]\+\"dolphot \"#\"$DOLPHOT_AST_BIN \"#; \
               s#\"/[^\"]*/bin/dolphot \" \+ dolphotout#\"$DOLPHOT_AST_BIN \" + dolphotout#" $F
    grep -q "\"$DOLPHOT_AST_BIN \" + dolphotout" $F || { fail "could not set DOLPHOT binary in $F"; continue; }

    # 4. queue it
    printf "%s\t%s\n" $run $sl >> $PENDING
    nok=$((nok+1))
done
if [ $DRY -eq 1 ]; then
    echo "dry run: nothing changed; $nfail problems"
else
    echo "$nok fields prepared and added to $PENDING; $nfail problems"
fi
