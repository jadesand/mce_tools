#!/bin/bash
#
# Take normal rate (data_mode 10) noise for all channels, at whatever
# row_len is currently set on the MCE. Pure data-taking: assumes the MCE is
# already reconfigured, biased, and has row_len/sample_dly/filter set for
# this run by the caller -- this script only runs the acquisition. --rowlen
# is used purely to label the output filename with the row_len in effect.
#
# RS - 2026-08-19 split out of noise_normal_fast_rowlen_ba_i6.sh
# RS - 2026-08-23 row_len/sample_dly/filter setting moved to the caller
#      (noise_taking_ba_i6.sh), since normal_dm10/normal_dm1/fast all sweep
#      the same row_len list and setting it three times per row_len was
#      redundant
# RS - 2026-10-21 --duration (seconds) instead of --nsamp; the sample count is
#      computed from num_rows/row_len/data_rate read off the MCE, so a
#      dataset lasts the same time at every row_len
#
# Usage: normal_dm10.sh [OPTIONS]
#   -d, --dir DIR         output directory to write into, relative to $MAS_DATA;
#                            must already exist. Use this when a master script
#                            has already created a per-bias subfolder.
#   -R, --run RUN          if --dir is not given, self-create and use
#                            $MAS_DATA/normal_dm10_run<RUN> (default: 0)
#   --overwrite              if --dir is not given, allow overwriting an
#                            existing normal_dm10_run<RUN> directory
#   -l, --rowlen ROWLEN     row_len currently in effect on the MCE, used only
#                            to label the output filename (default: 89)
#   -t, --duration SEC      seconds of data to acquire (default: 10); converted
#                            to samples at fs=50e6/(num_rows*row_len*data_rate)

source $MAS_SCRIPT/mas_library.bash

SCRIPT_NAME=$(basename "$0")
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"
SCRIPT_FULL_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_FULL_PATH")

####################################################################
# parse arguments
####################################################################

dir=""
run="0"
overwrite="false"
rowlen=89
duration=10

opts=$(getopt -o d:R:l:t: \
    --long dir:,run:,overwrite,rowlen:,duration: \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        -d|--dir)       dir="$2"; shift 2 ;;
        -R|--run)       run="$2"; shift 2 ;;
        --overwrite)    overwrite="true"; shift ;;
        -l|--rowlen)    rowlen="$2"; shift 2 ;;
        -t|--duration)  duration="$2"; shift 2 ;;
        --)             shift; break ;;
        *)              echo "Unknown option: $1"; exit 1 ;;
    esac
done

####################################################################
# resolve output directory: explicit --dir, or self-create from --run
#
# dir is kept RELATIVE to $MAS_DATA throughout (mce_run prepends
# $MAS_DATA itself); use $MAS_DATA/$dir for plain filesystem ops
# (mkdir, cp, tee, redirects).
####################################################################

if [ -n "$dir" ]; then
    # Explicit --dir: caller (e.g. a master script) already created this,
    # just use it.
    if [ ! -d "$MAS_DATA/$dir" ]; then
        echo "Error: output directory not found: $MAS_DATA/$dir"
        exit 1
    fi
else
    basedir=$SCRIPT_NAME_NO_EXT'_run'$run
    if [ -d $MAS_DATA/$basedir ]; then
        if [ "$overwrite" != "true" ]; then
            echo "Directory $MAS_DATA/$basedir already exists! Please choose a different run number or use --overwrite."
            exit 1
        else
            echo "Overwriting existing directory $MAS_DATA/$basedir"
            rm -rf $MAS_DATA/$basedir
            mkdir $MAS_DATA/$basedir
        fi
    else
        mkdir $MAS_DATA/$basedir
    fi
    dir=$basedir

    # Archive this script and log all output.
    cp "$SCRIPT_FULL_PATH" "$MAS_DATA/$dir/$SCRIPT_NAME"
    exec > >(tee -a "$MAS_DATA/$dir/${SCRIPT_NAME_NO_EXT}.log") 2>&1
    echo "=== $(date) starting $SCRIPT_NAME ==="
fi

####################################################################
# START DATA ACQUISITION
####################################################################

sleep 1
mce_cmd -qx wb rca data_mode 10
sleep 1

# convert duration to a sample count at the rate currently on the MCE
num_rows=$(command_reply rb sys num_rows | awk '{print $1}')  # one value per card; take the first
mce_rowlen=$(command_reply rb sys row_len | awk '{print $1}')
data_rate=$(command_reply rb cc data_rate)
read fs nsamp <<< $(awk -v t="$duration" -v n="$num_rows" -v r="$mce_rowlen" -v dr="$data_rate" \
    'BEGIN { fs = 50e6/(n*r*dr); printf "%.2f %d\n", fs, t*fs + 0.5 }')
if [ -z "$nsamp" ] || [ "$nsamp" -lt 1 ]; then
    echo "Error: could not compute nsamp (num_rows=$num_rows row_len=$mce_rowlen data_rate=$data_rate)" >&2
    exit 1
fi
echo "duration=${duration}s at fs=${fs} Hz (num_rows=$num_rows, row_len=$mce_rowlen, data_rate=$data_rate) -> nsamp=$nsamp"

echo "taking normal, downsampled (data_mode 10), noise for all channels, row_len=$rowlen"

mce_run $dir'/all_rcs_datamode10_rowlen'$rowlen $nsamp s # t = nsamp/fs = duration

sleep 1

mce_status -s > "$MAS_DATA/$dir/mce_status.txt"
