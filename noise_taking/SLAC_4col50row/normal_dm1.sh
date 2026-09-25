#!/bin/bash
#
# Take normal rate (data_mode 1) noise for all channels, at whatever row_len
# is currently set on the MCE. Pure data-taking: assumes the MCE is already
# reconfigured, biased, and has row_len/sample_dly/filter set for this run
# by the caller -- this script only runs the acquisition. --rowlen is used
# purely to label the output filename with the row_len in effect.
#
# RS - 2026-08-19 split out of noise_normal_fast_rowlen_ba_i6.sh
# RS - 2026-08-23 row_len/sample_dly/filter setting moved to the caller
#      (noise_taking_ba_i6.sh), since normal_dm10/normal_dm1/fast all sweep
#      the same row_len list and setting it three times per row_len was
#      redundant
#
# Usage: normal_dm1.sh [OPTIONS]
#   -d, --dir DIR         output directory to write into, relative to $MAS_DATA;
#                            must already exist. Use this when a master script
#                            has already created a per-bias subfolder.
#   -R, --run RUN          if --dir is not given, self-create and use
#                            $MAS_DATA/normal_dm1_run<RUN> (default: 0)
#   --overwrite              if --dir is not given, allow overwriting an
#                            existing normal_dm1_run<RUN> directory
#   -l, --rowlen ROWLEN     row_len currently in effect on the MCE, used only
#                            to label the output filename (default: 119)
#   -n, --nsamp N           number of samples to acquire (default: 6800)

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
rowlen=70
nsamp=6000

opts=$(getopt -o d:R:l:n: \
    --long dir:,run:,overwrite,rowlen:,nsamp: \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        -d|--dir)       dir="$2"; shift 2 ;;
        -R|--run)       run="$2"; shift 2 ;;
        --overwrite)    overwrite="true"; shift ;;
        -l|--rowlen)    rowlen="$2"; shift 2 ;;
        -n|--nsamp)     nsamp="$2"; shift 2 ;;
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
mce_cmd -qx wb rca data_mode 1
sleep 1

echo "taking normal, data_mode 1, noise for all channels, row_len=$rowlen"

mce_run $dir'/all_rcs_datamode1_rowlen'$rowlen $nsamp s # this corresponds to t= #samples/fs (sec)

sleep 1

mce_status -s > "$MAS_DATA/$dir/mce_status.txt"
