#!/bin/bash

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
TASK_FILE="$SCRIPT_DIR/multitask.sh"

run_index=0
force=0

opts=$(getopt -o r:f --long run-index:,force -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        -r|--run-index) run_index="$2"; shift 2 ;;
        -f|--force)     force=1; shift ;;
        --)             shift; break ;;
        *)              echo "Unknown option: $1"; exit 1 ;;
    esac
done

MAS_DATA_REAL=$(readlink -f "$MAS_DATA")
RUN_DIR="$MAS_DATA_REAL/multitask_run${run_index}"

if [[ -e "$RUN_DIR" ]]; then
    if [[ "$force" -eq 1 ]]; then
        rm -rf "$RUN_DIR"
    else
        echo "Error: $RUN_DIR already exists. Use -f/--force to overwrite, or pick a different -r/--run-index." >&2
        exit 1
    fi
fi

# RUN_DIR is created now (before the run) purely so we have somewhere to
# log to from the start. It's still created before any dataset dirs, so it
# can never be mistaken for a freshly created dataset dir by
# run_mce_raw_acq_two_level.sh's "most recently modified dir" search.
mkdir -p "$RUN_DIR/analysis"

main() {
    # Snapshot existing top-level dirs so we only collect what this run creates
    before_data=$(find "$MAS_DATA_REAL" -maxdepth 1 -type d -not -path "$MAS_DATA_REAL")
    before_analysis=$(find "$MAS_DATA_REAL/analysis" -maxdepth 1 -type d -not -path "$MAS_DATA_REAL/analysis" 2>/dev/null)

    (cd "$SCRIPT_DIR" && bash "$TASK_FILE")

    # Move newly created top-level dirs into the run directory
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        if [[ "$dir" != "$RUN_DIR" ]] && ! grep -qxF "$dir" <<< "$before_data"; then
            mv "$dir" "$RUN_DIR/"
        fi
    done < <(find "$MAS_DATA_REAL" -maxdepth 1 -type d -not -path "$MAS_DATA_REAL")

    # Move newly created analysis dirs into the run directory's analysis subfolder
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        if ! grep -qxF "$dir" <<< "$before_analysis"; then
            mv "$dir" "$RUN_DIR/analysis/"
        fi
    done < <(find "$MAS_DATA_REAL/analysis" -maxdepth 1 -type d -not -path "$MAS_DATA_REAL/analysis" 2>/dev/null)

    # Keep a copy of the task file for record
    cp "$TASK_FILE" "$RUN_DIR/multitask.sh"

    echo "Run artifacts collected in $RUN_DIR"
}

main 2>&1 | tee "$RUN_DIR/log"
