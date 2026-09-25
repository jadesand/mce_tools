#!/bin/bash

# Usage: noise_two_level_normal.sh [OPTIONS]
#   -t, --tune-ctime CTIME   tune ctime (REQUIRED)
#   --overwrite              allow overwriting existing directory
#   -r, --run RUN            output run extension (default: 0)
#   -c, --configprefix PFX   config file prefix (default: config)
#   -C, --max-cols N         total number of columns (default: 8)
#   -R, --max-rows N         total number of rows (default: 41)
#   -l, --row-len N          length of each row (default: 119)
#   -u, --unlatch-value V    bias value for unlatching detectors (default: 65535)
#   -b, --unlatch-bias-mode M  "all", "half", or "manual" (default: all)
#   -f, --f-cutoff HZ        Butterworth filter cutoff frequency in Hz (default: 75)


source $MAS_SCRIPT/mas_library.bash

SCRIPT_NAME=$(basename "$0")
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"
SCRIPT_FULL_PATH=$(readlink -f "$0")

# Default values
tune_ctime=""
overwrite="false"
run="0"
configprefix="config"
# max_cols=8
max_rows=11
row_len=119
unlatch_value=65535
unlatch_bias_mode="all"
f_cutoff=75

# Parse keyword arguments with getopt
opts=$(getopt -o t:r:c:C:R:l:u:b:f: \
    --long tune-ctime:,overwrite,run:,configprefix:,max-cols:,max-rows:,row-len:,unlatch-value:,unlatch-bias-mode:,f-cutoff: \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        -t|--tune-ctime)        tune_ctime="$2"; shift 2 ;;
        --overwrite)            overwrite="true"; shift ;;
        -r|--run)               run="$2"; shift 2 ;;
        -c|--configprefix)      configprefix="$2"; shift 2 ;;
        # -C|--max-cols)          max_cols="$2"; shift 2 ;;
        -R|--max-rows)          max_rows="$2"; shift 2 ;;
        -l|--row-len)           row_len="$2"; shift 2 ;;
        -u|--unlatch-value)     unlatch_value="$2"; shift 2 ;;
        -b|--unlatch-bias-mode) unlatch_bias_mode="$2"; shift 2 ;;
        -f|--f-cutoff)          f_cutoff="$2"; shift 2 ;;
        --)                     shift; break ;;
        *)                      echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate required arguments
if [ -z "$tune_ctime" ]; then
    echo "Error: --tune-ctime is required"
    exit 1
fi

# Define tune directory based on tune_ctime
tune_dir="$MAS_DATA/two_level_$tune_ctime"

# Make directory for this run, checking for existing directory first
basedir=$SCRIPT_NAME_NO_EXT'_run'$run
if [ -d $MAS_DATA/$basedir ]; then
    if [ "$overwrite" != "true" ]; then
        echo "Directory $MAS_DATA/$basedir already exists! Please choose a different run number or use overwrite=true."
        exit 1
    fi
else
    mkdir $MAS_DATA/$basedir
fi

# Set Butterworth filter coefficients for current row_len and f_cutoff
BUTTER_SCRIPT=$(dirname "$SCRIPT_FULL_PATH")/../../python/mce_butter_params.py
set_butter_filter() {
    local rlen=$1
    local params=$(python $BUTTER_SCRIPT $max_rows $rlen $f_cutoff)
    # params is a list like [b11, b12, b21, b22, k1, k2]
    local vals=$(echo $params | tr -d '[],' )
    echo "setting fltr_coeff for row_len=$rlen, f_cutoff=$f_cutoff Hz: $vals"
    mce_cmd -qx wb rca fltr_coeff $vals
}


####################################################################
# initial set up, and archiving config and script stuff
####################################################################
mas_param set config_sync 0

####################################################################
# START DATA ACQUISITION
####################################################################

# Archive scripts and config files
cp $SCRIPT_FULL_PATH $MAS_DATA/$basedir/script

echo "bias and settle for 10s"
echo "taking normal, noise for all channels at tes_bias=0"
bias_tess 0

sleep 10


for cs_dir in $(ls -d "$tune_dir"/CS* | sort -t S -k 2 -n); do
    cs=$(basename "$cs_dir")
    echo "Processing $cs"

    # Create CS subdirectory in basedir
    mkdir -p "$MAS_DATA/$basedir/$cs"

    # Copy experiment.cfg from tune directory
    cp "$cs_dir/experiment.cfg" "$MAS_DATA/$basedir/$cs/"

    # Set up MCE for this CS
    mce_zero_bias > /dev/null 2>&1
    sleep 1
    mce_make_config -x -e "$MAS_DATA/$basedir/$cs/experiment.cfg"
    sleep 5

    # Data acquisition
    mce_cmd -qx wb sys row_len $row_len
    sleep 1
    mce_cmd -qx wb rca sample_dly $(($row_len-10))
    sleep 1
    set_butter_filter $row_len
    sleep 5

    echo "row_len set to: $(command_reply rb sys row_len)"
    echo "sample_dly set to: $(command_reply rb rca sample_dly)"

    if [ "$overwrite" = "true" ]; then
        rm -f $MAS_DATA/$basedir/$cs/'all_rcs_datamode10_rowlen'$row_len*
    fi
    mce_run $basedir/$cs/'all_rcs_datamode10_rowlen'$row_len 6800 s # this corresponds to t= #samples/fs (sec)
    # mce_run $basedir/$cs/'all_rcs_datamode10_rowlen'$row_len 100 s # this corresponds to t= #samples/fs (sec)

    sleep 5
    mce_cmd -qx wb rca data_mode 1
    sleep 5
    if [ "$overwrite" = "true" ]; then
        rm -f $MAS_DATA/$basedir/$cs/'all_rcs_datamode1_rowlen'$row_len*
    fi
    mce_run $basedir/$cs/'all_rcs_datamode1_rowlen'$row_len 6800 s # this corresponds to t= #samples/fs (sec)
    # mce_run $basedir/$cs/'all_rcs_datamode1_rowlen'$row_len 100 s # this corresponds to t= #samples/fs (sec)

    sleep 1
    mce_make_config -x -e "$MAS_DATA/$basedir/$cs/experiment.cfg"
    sleep 3
done

