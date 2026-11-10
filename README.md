# wings-bulk-runs

Scripts for running the wingspipe DOLPHOT pipeline (`phat_pypipeline_repo`) on many JWST fields at once on Great Lakes. A small queue script runs as a SLURM job, submits fields one batch at a time, and records each field's progress in a status file. You launch a whole campaign with one command and come back later.

There are two queues:

| Queue | What it does | How many fields at once |
|---|---|---|
| **Photometry** (`photometry/`) | Sets up and runs the full pipeline (image prep through DOLPHOT and the final catalogs) | `MAXACTIVE`, default 4 |
| **ASTs** (`ast/`) | Runs artificial star tests on fields whose photometry is finished | 1, because one field's AST jobs fill the group allocation |

## Contents

```
config.example.sh            site settings: copy to config.sh and edit
lib/common.sh                shared helpers (config loading, SQL check, queue submission)
photometry/
  prep_fields.sh             set up a run directory for every field that doesn't have one
  submit_queue.sh            start the photometry queue as a SLURM job
  run_queue.sh               the queue itself (run by submit_queue.sh)
  queue_report.sh            status of every queued field
ast/
  ast_prep.sh                prepare finished fields for ASTs and add them to the AST queue
  submit_ast_queue.sh        start the AST queue as a SLURM job
  ast_queue.sh               the queue itself (run by submit_ast_queue.sh)
  ast_report.sh              status of every queued field, plus progress of the running one
```

## Setup

You need:
- a Great Lakes account on the SLURM account in `config.sh`;
- a Python environment with `wingspipe` installed (we use `micromamba activate stenv-py313`);
- the credentials for the wpipe SQL server.

```bash
git clone /nfs/turbo/lsa-ericbell1/vvrao/wings-bulk-runs
cd wings-bulk-runs
cp config.example.sh config.sh
```

Edit `config.sh`. It is commented, and git ignores it so your paths and the database password never get committed. The settings you will most likely change:
- `PIPE_DIR` is your own pipelines directory. Every run directory, queue list, status file and queue log lives there.
- `ENV_SETUP` is the command that activates your environment.
- `SQL_USER` and `SQL_PASS` are the database credentials.

The other paths point at shared inputs (images, configs, AST lists, DOLPHOT), which most people can leave as they are.

All the scripts work from any directory.

## Running photometry for many fields

### 1. Set up the run directories

```bash
photometry/prep_fields.sh --dry-run        # list what would be set up
photometry/prep_fields.sh                  # set them up
photometry/prep_fields.sh --only ngc1808_f1   # just one field
```

`prep_fields.sh` handles every visit in `IMG_DIR`, which has one directory per visit: `<GAL>_vNN/{NIRCam,NIRISS}/crf/`. Visits are named like this:
- **NIRCam:** the lower visit number becomes `<gal>_f1` and the higher one `<gal>_f2`.
- **NIRISS:** the same, with `_nis_` added: `<gal>_nis_f1` and `<gal>_nis_f2`.

For each field that has no run directory yet, the script:
1. writes the image list to `PIPE_DIR/<gal>/<field>`;
2. creates `PIPE_DIR/<field>r1/`;
3. runs `wingspipe init` there;
4. appends `<field>r1` to `PIPE_DIR/pending_fields.txt`.

It never submits anything, and it skips any field that already has a run directory, so it's safe to run again.

To queue a run you set up by hand, for example a rerun, add its directory name to `pending_fields.txt` yourself. A rerun always needs a new `rN` directory, because the pipeline database registers each directory as its own pipeline.

### 2. Start the queue

```bash
photometry/submit_queue.sh
```

This submits `run_queue.sh` as a 7-day, 1-CPU SLURM job. Every 10 minutes the queue does the following:
- **Status.** It marks a field DONE once its final plot (`*_gst_spatial.png`) exists. It marks a field STALLED if it has no SLURM jobs left and no final plot.
- **Launching.** It runs `wingspipe run` on the next fields in `pending_fields.txt` until `MAXACTIVE` are in flight.
- **Database.** Before each launch, it checks the SQL server's `max_connections` (see [Things to know](#things-to-know)).

The queue exits when every field is DONE or STALLED. If the 7 days run out first, run `submit_queue.sh` again; the new job picks up where the old one stopped.

### 3. Watch it

```bash
photometry/queue_report.sh            # every field
photometry/queue_report.sh STALLED    # just one state
```

The report shows each field's:
- state;
- number of SLURM jobs in flight;
- last pipeline step submitted;
- minutes since that submission.

An ACTIVE field whose `idle_min` grows far past the step's usual runtime may have a hung job.

These files in `PIPE_DIR` control a running queue:
- **`queue.conf`:** write `MAXACTIVE=<n>` here to change how many fields run at once. The queue re-reads it every loop.
- **`PAUSE`:** create this file to stop new launches. Fields already running carry on. Delete it to resume.
- **`queue_status.tsv`:** each field's state, launch time and end time.
- **`run_queue_<jobid>.log`:** the queue's own log.

A STALLED field is never relaunched automatically. To find out why it stopped, start in its run directory:
- `config/*.list` holds the command each SLURM job ran;
- `slurm-<jobid>.out` holds that job's output;
- `sacct -j <jobid> -o jobid,state,elapsed,maxrss,reqmem` shows whether it failed, ran out of memory or timed out.

To rerun a field, set it up in a new `rN` directory and add that directory to `pending_fields.txt`.

## Running ASTs for many fields

ASTs need a finished photometry run (`<field>.phot` in the run's `proc_*` directory) and an AST input list at `AST_INPUT_DIR/<field>/<field>_inputAST_final.txt`.

### 1. List the fields

Write a plain text file with one run directory name per line. When a field has several runs, use the one whose photometry you released.

```
ngc1808_f1r1
ngc1808_nis_f1r1
ngc1532_f1r6
```

The queue runs the fields in the order you list them.

### 2. Prepare them

```bash
ast/ast_prep.sh --dry-run my_fields.txt    # check everything, change nothing
ast/ast_prep.sh my_fields.txt
```

For each field, `ast_prep.sh` does the following:
- **Fakelist.** It copies the input list, without its header row, to `proc_*/<field>.fakelist`. It never overwrites an existing `.fakelist`; if a field already has one, it reports the field and skips it.
- **Memory.** It sets the per-job memory in the run's `build/split_fakestars.py`:

  | Field | Memory |
  |---|---|
  | NIRCam | 50G, or 80G if the real-star catalog has more than 250k stars |
  | NIRISS | 80G |

  Each job runs 10 chunks of 100 stars on one node and shares this memory between them. You can change the thresholds in `config.sh`.
- **Checks.** It confirms `starsper = 100` and 6-hour walltimes.
- **DOLPHOT.** It points `build/run_fakestars.py` at `DOLPHOT_AST_BIN`, which is dolphot2.1.
- **Queueing.** It adds the field to `PIPE_DIR/ast_pending.txt`, together with the script that launches its ASTs.

The dry run prints the table it would act on: stars, AST rows, chunks, memory and launch script.

Running `ast_prep.sh` again with more fields appends them to the queue, even while the queue is running.

### 3. Start the queue

```bash
ast/submit_ast_queue.sh
```

The queue launches one field. When that field has had no SLURM jobs for two checks in a row, it records the field's results and launches the next one. Launching a field means:
1. checking the SQL server's `max_connections`;
2. resubmitting the field's original `split_fakestars.py` job. That job ran once during the photometry and stopped because there was no `.fakelist` yet. This time it splits the list into 100-star chunks, and the pipeline submits the chunk jobs in batches of 10.

A field with about 1,500 chunks takes a few hours when the cluster isn't busy.

### 4. Watch it

```bash
ast/ast_report.sh
```

For each field, the report shows:

| Column | Meaning |
|---|---|
| `chunks` | chunks expected |
| `outputs` | output files that exist |
| `empty` | output files that are empty |
| `completed` | chunk logs that end with `Completed N artificial stars` |

For the running field it also shows the jobs in flight. A healthy finished field has all four numbers equal, or `empty` = 0.

These files in `PIPE_DIR` control a running AST queue:
- **`AST_PAUSE`:** create this file to stop new launches. The running field carries on. Delete it to resume.
- **`ast_queue_status.tsv`:** each field's job ID, times, state and final counts.
- **`ast_queue_<jobid>.log`:** the queue's own log.

The AST queue pauses itself if any chunk log reports `Cannot open`, or if a field finishes with no output at all. Either one usually means something is wrong for every field, such as a missing PSF file. Fix the cause, delete `AST_PAUSE`, and the queue continues.

### 5. Missing or failed chunks

The queue records failed chunks and moves on; it doesn't rerun them. In the report they appear in two ways:
- **`empty` > 0:** the chunk's job was killed, almost always for running out of memory. DOLPHOT still leaves an empty output file behind, and the pipeline counts the chunk as done.
- **`outputs` < `chunks`:** the chunk was never submitted. Occasionally the pipeline drops a few events.

To rerun a field's failed chunks:
1. Delete the field's **empty** `<field>.phot_<i>.fake` files. When the split restarts, it skips every chunk whose output file exists, even an empty one.
2. If memory was the cause, raise the memory in `build/split_fakestars.py`.
3. Resubmit the field's launch script, which is listed in `ast_pending.txt`, from inside the run directory. Only the missing chunks run.

```bash
cd $PIPE_DIR/<run>
find data/<field>/proc_* -name '<field>.phot_*.fake' -size 0 -delete
sbatch <launch script from ast_pending.txt>
```

Check `squeue` first so you don't do this while the AST queue is running another field: both would compete for the same allocation.

## Things to know

- **Database connections.** Each pipeline job opens a connection to the shared wpipe SQL server. With the default limit of 151, a large batch fails with `Too many connections` in the run directory's `slurm-*.out`. Both queues raise the limit to `SQL_MAX_CONNECTIONS` (1500) before every launch. The limit resets whenever the server restarts or moves to a new address, and the address is read fresh from `SQL_SERVER_FILE` each time. If the server can't be reached, the queue waits rather than launching.
- **One AST campaign per allocation.** One field's AST jobs fill the group allocation. If two people run AST queues on the same SLURM account, both slow down. Coordinate who is running.
- **dolphot2.1 for ASTs.** dolphot3.x obeys the `MaxThreads` setting in the parameter file. With 10 chunks sharing a node that oversubscribes the CPUs, and the run slows down about 100×. dolphot2.1 ignores `MaxThreads`. Its `nircam/data` and `niriss/data` directories must contain a PSF file for every filter you use; otherwise every chunk fails with `Cannot open .../F115W.psf`.
- **Edits after setup.** `wingspipe init` copies `BUILD_DIR` into each run directory. Later changes to `phat_pypipeline_repo/build` do not reach runs that already exist. `ast_prep.sh` edits the copies in each run's own `build/`.
- **Chip gaps.** Fake stars that land in a detector gap produce no output row. A field can therefore finish cleanly with fewer AST rows than input stars.
