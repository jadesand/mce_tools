#!/bin/bash
#
# Take fast (~10kHz, closed loop, unfiltered feedback) noise data for all
# columns of each listed row, looped over a list of row_len values. One
# row is read out per acquisition.
#
# Pure data-taking: assumes the MCE is already reconfigured and biased for
# this run by the caller; this script only sets row_len/sample_dly
# (acquisition parameters, not shared MCE state) and runs the acquisition.
#
# RS - 2026-08-19 split out of noise_normal_fast_rowlen_ba_i6.sh
# RS - 2026-08-20 switched from row-chunking to a row list, one row per acquisition
#
# Usage: fast.sh [OPTIONS]
#   -d, --dir DIR             output directory to write into; must already exist.
#                                Use this when a master script has already created a
#                                per-bias subfolder. (absolute, or relative to $MAS_DATA)
#   -R, --run RUN              if --dir is not given, self-create and use
#                                $MAS_DATA/fast_run<RUN> (default: 0)
#   --overwrite                 if --dir is not given, allow overwriting an
#                                existing fast_run<RUN> directory
#   -l, --rowlens LIST         comma-separated row_len values to loop over (required)
#   -r, --row-list FILE        text file listing rows to read out, one per line,
#                                with optional comment lines starting with # (required)
#   -n, --nsamp N              number of samples to acquire per row (default: 204000)

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
row_list="fast_row_list.txt"
nsamp=204000

opts=$(getopt -o d:R:l:r:n: \
    --long dir:,run:,overwrite,rowlens:,row-list:,nsamp: \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        -d|--dir)            dir="$2"; shift 2 ;;
        -R|--run)            run="$2"; shift 2 ;;
        --overwrite)         overwrite="true"; shift ;;
        -l|--rowlens)        rowlens="$2"; shift 2 ;;
        -r|--row-list)       row_list="$2"; shift 2 ;;
        -n|--nsamp)          nsamp="$2"; shift 2 ;;
        --)                  shift; break ;;
        *)                   echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$row_list" ]; then
    echo "Error: --row-list is required"
    exit 1
fi
if [ ! -f "$row_list" ]; then
    echo "Error: row list file not found: $row_list"
    exit 1
fi

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

    # Archive this script and the row list, and log all output.
    cp "$SCRIPT_FULL_PATH" "$dir/$SCRIPT_NAME"
    cp "$row_list" "$dir/row_list.txt"
    exec > >(tee -a "$dir/${SCRIPT_NAME_NO_EXT}.log") 2>&1
    echo "=== $(date) starting $SCRIPT_NAME ==="
fi

# Read row list file (format: one row per line)
rows=$(grep -v '^\s*#' "$row_list" | grep -v '^\s*$')

####################################################################
# build one fast.scr per row, setting fast_ccnumrows/fast_rcnumrows/
# readout_row_index for that row
####################################################################

fast_datamode=1
fast_datarate=1

declare -A fast_scripts=()
while IFS=' ' read -r row; do
    fast_script=$dir/fast_row${row}.scr
    echo "wb rca data_mode "$fast_datamode >> $fast_script
    echo "wb cc num_rows_reported 1" >> $fast_script
    echo "wb rca num_rows_reported 1" >> $fast_script
    echo "wb cc data_rate "$fast_datarate >> $fast_script
    echo "wb rca readout_row_index "$row >> $fast_script
    fast_scripts[$row]="$fast_script"
done <<< "$rows"

####################################################################
# START DATA ACQUISITION
# loop over row_len, and within each, over the listed rows
####################################################################

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

    echo "taking fast data, row_len=$rlen"

    while IFS=' ' read -r row; do
        echo "taking fast data for row $row"
        mce_cmd -iqf ${fast_scripts[$row]}
        sleep 1
        fast_filename=$dir'/fast_rowlen'$rlen'_row'$row
        mce_run $fast_filename $nsamp s  # this corresponds to t= #samples/fs (sec), fs=10 kHz
        sleep 1
    done <<< "$rows"
done

mce_status -s > "$dir/mce_status.txt"
