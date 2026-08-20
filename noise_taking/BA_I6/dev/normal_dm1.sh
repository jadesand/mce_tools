#!/bin/bash
#
# Take normal rate (data_mode 1) noise for all channels, looped over
# a list of row_len values. Pure data-taking: assumes the MCE is already
# reconfigured and biased for this run by the caller; this script only sets
# row_len/sample_dly (acquisition parameters, not shared MCE state) and
# runs the acquisition. Data_mode 1 is raw data, so unlike data_mode 10 it
# is taken without the Butterworth filter.
#
# RS - 2026-08-19 split out of noise_normal_fast_rowlen_ba_i6.sh
#
# Usage: normal_dm1.sh [OPTIONS]
#   -d, --dir DIR         output directory to write into; must already exist.
#                            Use this when a master script has already created a
#                            per-bias subfolder. (absolute, or relative to $MAS_DATA)
#   -R, --run RUN          if --dir is not given, self-create and use
#                            $MAS_DATA/normal_dm1_run<RUN> (default: 0)
#   --overwrite              if --dir is not given, allow overwriting an
#                            existing normal_dm1_run<RUN> directory
#   -l, --rowlens LIST      comma-separated row_len values to loop over (required)
#   -n, --nsamp N           number of samples to acquire per row_len (default: 6800)

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
rowlens=119
nsamp=6800

opts=$(getopt -o d:R:l:n: \
    --long dir:,run:,overwrite,rowlens:,nsamp: \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        -d|--dir)       dir="$2"; shift 2 ;;
        -R|--run)       run="$2"; shift 2 ;;
        --overwrite)    overwrite="true"; shift ;;
        -l|--rowlens)   rowlens="$2"; shift 2 ;;
        -n|--nsamp)     nsamp="$2"; shift 2 ;;
        --)             shift; break ;;
        *)              echo "Unknown option: $1"; exit 1 ;;
    esac
done

####################################################################
# resolve output directory: explicit --dir, or self-create from --run
####################################################################

if [ -n "$dir" ]; then
    # Explicit --dir: caller (e.g. a master script) already created this,
    # just use it.
    if [ ! -d "$dir" ] && [ ! -d "$MAS_DATA/$dir" ]; then
        echo "Error: output directory not found: $dir"
        exit 1
    fi
    [ -d "$dir" ] || dir="$MAS_DATA/$dir"
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
    dir=$MAS_DATA/$basedir

    # Archive this script and log all output.
    cp "$SCRIPT_FULL_PATH" "$dir/$SCRIPT_NAME"
    exec > >(tee -a "$dir/${SCRIPT_NAME_NO_EXT}.log") 2>&1
    echo "=== $(date) starting $SCRIPT_NAME ==="
fi

####################################################################
# START DATA ACQUISITION
# loop over row_len
####################################################################

sleep 1
mce_cmd -qx wb rca data_mode 1
sleep 1

IFS=',' read -ra rlen_arr <<< "$rowlens"
for rlen in "${rlen_arr[@]}"
do
    echo "setting row_len="$rlen

    sleep 1
    mce_cmd -qx wb sys row_len $rlen
    sleep 1
    mce_cmd -qx wb rca sample_dly $(($rlen-10))
    sleep 1

    echo "row_len set to: $(command_reply rb sys row_len)"
    echo "sample_dly set to: $(command_reply rb rca sample_dly)"

    echo "taking normal, data_mode 1, noise for all channels, row_len=$rlen"

    sleep 1
    mce_run $dir'/all_rcs_datamode1_rowlen'$rlen $nsamp s # this corresponds to t= #samples/fs (sec)

    sleep 1
done

mce_status -s > "$dir/mce_status.txt"
