#!/bin/bash

SCRIPT_NAME=$(basename "$0")
FREEZE_SCRIPT="/home/mce/rshi/mce_scripts/python/mce_freeze_servo_mux11d.py"
RECONFIG_SCRIPT="/home/mce/rshi/mce_scripts/script/reconfig_two_level.sh"

tune_ctime=""
date="current_data"
columns=(4 5 6 7)
chips=(11)
rcs=(2)
freeze_stage=""
row=0
ndatasets=50


# Parse keyword arguments
opts=$(getopt -o t:R:c:C:d:f:r:n: \
    --long tune-ctime:,rcs:,col:,chip:,date:,freeze-stage:,row:,ndatasets: \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        -t|--tune-ctime)    tune_ctime="$2"; shift 2 ;;
        -R|--rcs)           IFS=',' read -r -a rcs     <<< "$2"; shift 2 ;;
        -c|--col)           IFS=',' read -r -a columns <<< "$2"; shift 2 ;;
        -C|--chip)          IFS=',' read -r -a chips   <<< "$2"; shift 2 ;;
        -d|--date)          date="$2"; shift 2 ;;
        -f|--freeze-stage)  freeze_stage="$2"; shift 2 ;;
        -r|--row)           row="$2"; shift 2 ;;
        -n|--ndatasets)     ndatasets="$2"; shift 2 ;;
        --)                 shift; break ;;
        *)                  echo "Unknown option: $1"; exit 1 ;;
    esac
done

MAS_DATA_REAL=$(readlink -f "$MAS_DATA")

PARENT_NAME="two_level_raw_$(date +%s)"
mkdir -p "$MAS_DATA_REAL/$PARENT_NAME"
mkdir -p "$MAS_DATA_REAL/analysis/$PARENT_NAME"

columns_str=$(IFS=,; echo "${columns[*]}")
rcs_str=$(IFS=,; echo "${rcs[*]}")

{
for CS in "${chips[@]}"; do
    if [[ -n "$freeze_stage" ]]; then
        echo "Freezing servo for CS=$CS, row=$row, stage=$freeze_stage..."
        mce_zero_bias > /dev/null
        sleep 1
        cp "$MAS_DATA_ROOT/${date}/two_level_${tune_ctime}/CS$((CS-10))/experiment.cfg" $MAS_DATA/experiment.cfg
        # Be careful here
        if [[ "$freeze_stage" == "preamp" ]] || [[ "$freeze_stage" == "sa" ]]; then
            auto_setup --rc=2 --last-stage=sa_ramp
        else
            auto_setup --rc=2 --last-stage=sq1_ramp
        fi
        sleep 1
        python "$FREEZE_SCRIPT" --row "$row" $freeze_stage
    else
        echo "No freeze stage specified, reconfig CS=$CS."
        bash "$RECONFIG_SCRIPT" -t "$tune_ctime" -c "$(($CS-10))" -d "$date"
    fi
    "$(dirname "$0")/run_mce_raw_acq.sh" -n "$ndatasets" -c "$columns_str" -R "$rcs_str"

    # Find the most recently created directory
    LATEST=$(find "$MAS_DATA_REAL" -maxdepth 1 -type d \
             -not -path "$MAS_DATA_REAL" \
             -not -path "$MAS_DATA_REAL/$PARENT_NAME" \
             -printf '%T+ %p\n' | sort -r | head -1 | cut -d' ' -f2-)

    if [[ -n "$LATEST" ]]; then
        DIRNAME=$(basename "$LATEST")
        mv "$MAS_DATA_REAL/$DIRNAME" "$MAS_DATA_REAL/$PARENT_NAME/CS$((CS-10))"
    fi
done
} 2>&1 | tee "$MAS_DATA_REAL/$PARENT_NAME/log"
