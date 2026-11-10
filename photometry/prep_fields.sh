#!/bin/bash
# Set up (wingspipe init, no run) every field that has no run directory yet.
#   Visits come from $IMG_DIR/<GAL>_vNN/. Lower visit number -> _f1, higher -> _f2.
#   NIRISS fields get _nis_. Fields with any existing <field>r* directory are skipped.
#   Each initialised run directory is appended to $PIPE_DIR/pending_fields.txt.
# Never submits anything. Safe to re-run.
# Usage: prep_fields.sh [--dry-run] [--only <field>]

REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
source $REPO/lib/common.sh

DRY=0; ONLY=""
while [ $# -gt 0 ]; do
    case $1 in
        --dry-run) DRY=1 ;;
        --only) ONLY=$2; shift ;;
        *) echo "unknown option $1" >&2; exit 1 ;;
    esac
    shift
done

if [ $DRY -eq 0 ]; then
    eval "$ENV_SETUP" || exit 1
fi

for GAL in $(ls $IMG_DIR | sed 's/_v[0-9]*$//' | sort -u); do
    gal=$(echo $GAL | tr 'A-Z' 'a-z')
    i=0
    for visit in $(ls -d $IMG_DIR/${GAL}_v* | xargs -n1 basename | sort -t v -k2 -n); do
        i=$((i+1))
        for cam in NIRCam NIRISS; do
            if [ $cam = NIRCam ]; then
                field=${gal}_f$i; conf=$CONF_NIRCAM
            else
                field=${gal}_nis_f$i; conf=$CONF_NIRISS
            fi
            [ -n "$ONLY" ] && [ "$ONLY" != "$field" ] && continue
            run=$PIPE_DIR/${field}r1

            # skip fields already run; retry an r1 whose init never completed
            existing=$(ls -d $PIPE_DIR/${field}r* 2>/dev/null)
            if [ -n "$existing" ] && { [ "$existing" != "$run" ] || [ -f $run/.wpipe/pipe.conf ]; }; then
                continue
            fi

            nfiles=$(find $IMG_DIR/$visit/$cam/crf -type f | wc -l)
            printf "%-18s %-14s %-7s %3d files  %s\n" ${field}r1 $visit $cam $nfiles $(basename $conf)
            [ $DRY -eq 1 ] && continue

            mkdir -p $PIPE_DIR/$gal
            [ -s $PIPE_DIR/$gal/$field ] || find $IMG_DIR/$visit/$cam/crf -type f > $PIPE_DIR/$gal/$field
            mkdir -p $run
            if (cd $run && wingspipe init -w $BUILD_DIR -i $PIPE_DIR/$gal/$field -c $conf) > $run/init.log 2>&1 \
                    && [ -f $run/.wpipe/pipe.conf ]; then
                echo ${field}r1 >> $PIPE_DIR/pending_fields.txt
            else
                echo "  INIT FAILED for ${field}r1 -- see $run/init.log"
            fi
        done
    done
done
