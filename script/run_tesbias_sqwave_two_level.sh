#!/bin/bash

# TES bias square wave calibration script.
# This script toggles all TES bias lines simultaneously while the servo is running
# (data_mode 10, filtered feedback), and records the feedback response.
# This provides an end-to-end calibration check: inject a known bias step,
# verify the feedback responds with the expected amplitude.
#
# The TES bias is controlled via `wb bc3 flux_fb` (which is where `tes bias` maps to
# on this system). All bias lines are toggled together (same step_size).
#
# Output: one file per CS, named calib_tesbias, containing all rows and columns.
#
# Usage: run_tesbias_sqwave.sh [OPTIONS]
#   -t, --tune-ctime CTIME       tune ctime (REQUIRED)
#   -r, --rc RC                  readout card for acq_config, e.g. 1, 2, s (default: 2)
#   --overwrite                  allow overwriting existing directory
#   -R, --run RUN                output run extension (default: 0)
#   -l, --row-len N              row length (default: 119)
#   -s, --step-size N            TES bias step amplitude in DAC units (default: 200)
#   -n, --n-cycles N             number of full square wave cycles (default: 50)
#   -p, --period N               frames per half-cycle (default: 50)
#   -f, --f-cutoff HZ            Butterworth filter cutoff frequency in Hz (default: 75)

source $MAS_SCRIPT/mas_library.bash

SCRIPT_NAME=$(basename "$0")
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"
SCRIPT_FULL_PATH=$(readlink -f "$0")

BUTTER_SCRIPT="/home/mce/rshi/mce_scripts/python/mce_butter_params.py"

# Default values
tune_ctime=""
rc="2"
overwrite="false"
run="0"
row_len=119
max_rows=11
step_size=2
n_cycles=50
period=50
f_cutoff=75

# Parse keyword arguments
opts=$(getopt -o t:r:R:l:s:n:p:f: \
    --long tune-ctime:,rc:,overwrite,run:,row-len:,step-size:,n-cycles:,period:,f-cutoff: \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        -t|--tune-ctime)    tune_ctime="$2"; shift 2 ;;
        -r|--rc)            rc="$2"; shift 2 ;;
        --overwrite)        overwrite="true"; shift ;;
        -R|--run)           run="$2"; shift 2 ;;
        -l|--row-len)       row_len="$2"; shift 2 ;;
        -s|--step-size)     step_size="$2"; shift 2 ;;
        -n|--n-cycles)      n_cycles="$2"; shift 2 ;;
        -p|--period)        period="$2"; shift 2 ;;
        -f|--f-cutoff)      f_cutoff="$2"; shift 2 ;;
        --)                 shift; break ;;
        *)                  echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate required arguments
if [ -z "$tune_ctime" ]; then
    echo "Error: --tune-ctime is required"
    exit 1
fi

# Number of TES bias lines
n_bias=16

# Define tune directory
tune_dir="$MAS_DATA/two_level_$tune_ctime"

# Make output directory
basedir=${SCRIPT_NAME_NO_EXT}'_run'$run
if [ -d "$MAS_DATA/$basedir" ]; then
    if [ "$overwrite" != "true" ]; then
        echo "Directory $MAS_DATA/$basedir already exists! Please choose a different run number or use --overwrite."
        exit 1
    fi
else
    mkdir "$MAS_DATA/$basedir"
fi

# Butterworth filter setup function
set_butter_filter() {
    local rlen=$1
    local params=$(python $BUTTER_SCRIPT $max_rows $rlen $f_cutoff)
    local vals=$(echo $params | tr -d '[],' )
    echo "setting fltr_coeff for row_len=$rlen, f_cutoff=$f_cutoff Hz: $vals"
    mce_cmd -qx wb rca fltr_coeff $vals
}

# Build a bias array string with all lines set to the same value
make_bias_array() {
    local val=$1
    local arr=""
    for ((i=0; i<n_bias; i++)); do
        arr="$arr $val"
    done
    echo $arr
}

####################################################################
# Archive script
####################################################################
cp "$SCRIPT_FULL_PATH" "$MAS_DATA/$basedir/script"

####################################################################
# initial setup
####################################################################
mas_param set config_sync 0

echo "Setting tes_bias=0 and settling for 1s"
bias_tess 0
sleep 1

####################################################################
# Main acquisition loop: iterate over all CS in the tune directory
####################################################################

for cs_dir in $(ls -d "$tune_dir"/CS* | sort -t S -k 2 -n); do
    cs=$(basename "$cs_dir")

    echo "=========================================="
    echo "Processing $cs"
    echo "=========================================="

    # Create CS subdirectory
    mkdir -p "$MAS_DATA/$basedir/$cs"

    # Copy experiment.cfg from tune directory
    cp "$cs_dir/experiment.cfg" "$MAS_DATA/$basedir/$cs/"

    # Set up MCE for this CS
    mce_zero_bias > /dev/null 2>&1
    sleep 1
    mce_make_config -x -e "$MAS_DATA/$basedir/$cs/experiment.cfg"
    sleep 1

    # Set row_len and Butterworth filter
    mce_cmd -qx wb sys row_len $row_len
    sleep 1
    mce_cmd -qx wb rca sample_dly $(($row_len - 10))
    sleep 1
    set_butter_filter $row_len
    sleep 1

    echo "row_len set to: $(command_reply rb sys row_len)"
    echo "sample_dly set to: $(command_reply rb rca sample_dly)"

    # Ensure tes bias is at zero
    bias_tess 0

    echo "------------------------------------------"
    echo "TES bias square wave: $cs step_size=$step_size n_cycles=$n_cycles"
    echo "------------------------------------------"

    # Build bias arrays: all lines toggled together
    bias_zero=$(make_bias_array 0)
    bias_high=$(make_bias_array $step_size)

    # Build the .scr file
    script=$MAS_TEMP/tesbias_sqwave.scr
    rm -f $script

    filename=$MAS_DATA/$basedir/$cs/calib_tesbias
    if [ "$overwrite" = "true" ]; then
        rm -f $filename*
    fi

    echo "acq_config $filename rc$rc" >> $script

    for ((icycle=0; icycle<n_cycles; icycle++)); do
        # High half-cycle
        # echo "wb bc3 flux_fb $bias_high" >> $script
        echo "wb tes bias $bias_high" >> $script
        echo "sleep 10" >> $script
        echo "acq_go $period" >> $script
        # Low half-cycle
        # echo "wb bc3 flux_fb $bias_zero" >> $script
        echo "wb tes bias $bias_zero" >> $script
        echo "sleep 10" >> $script
        echo "acq_go $period" >> $script
    done

    # Restore bias to zero
    # echo "wb bc3 flux_fb $bias_zero" >> $script
    echo "wb tes bias $bias_zero" >> $script

    # Execute
    echo "running tesbias_sqwave.scr"
    mce_cmd -iqf $script
    echo "done"

    # Archive the script
    cp $script "$MAS_DATA/$basedir/$cs/tesbias_sqwave.scr"

    # Reconfigure MCE before next CS
    sleep 1
    mce_make_config -x -e "$MAS_DATA/$basedir/$cs/experiment.cfg"
    sleep 1

done

# Final cleanup
bias_tess 0
echo "TES bias square wave calibration complete."
