#!/bin/bash
#
# Master noise-taking script for BA module I6. Owns whole-run MCE state
# (initial reconfig, tes_bias sweep, per-bias-step reconfig) and dispatches
# to the standalone data-taking sub-scripts (normal_dm10.sh, normal_dm1.sh,
# fast.sh, superfast.sh) for whichever --type(s) of noise are requested,
# in the order given, at every bias step.
#
# Detectors are assumed to already be unlatched and biased into the
# transition by a separate script before this one runs (same assumption as
# noise_normal_fast_rowlen_ba_i6.sh / noise_superfast_ba_i6.sh) -- this
# script steps tes_bias down from high to low without ever latching.
#
# RS - 2026-08-20 master script dispatching to dev/ sub-scripts
#
# Usage: noise_taking_ba_i6.sh --type TYPE[,TYPE...] [OPTIONS]
#   --type TYPE[,TYPE...]        required: comma-separated list of one or more of
#                                  n (normal), f (fast), s (superfast), e.g. "n",
#                                  "f,s", or "n,f,s". For each bias step, the
#                                  requested types run in the order given: n runs
#                                  normal_dm10.sh then normal_dm1.sh; f runs
#                                  fast.sh; s runs superfast.sh.
#   -R, --run RUN                output run extension (default: 0)
#   --overwrite                   allow overwriting an existing basedir
#   -C, --configprefix PFX       config file prefix (default: config)
#   --max-cols N                  total number of columns: 16 or 32 (default: 16)
#   --max-rows N                   total number of rows (default: 41)
#   -b, --tes-bias-list FILE     text file with the tes_bias sweep (line 1) and
#                                  fixed bias columns (line 2) (default:
#                                  tes_bias_list.txt)
#   -l, --rowlens LIST            comma-separated row_len values, passed through to
#                                  normal_dm10.sh/normal_dm1.sh/fast.sh (default: 119)
#   -r, --row-list FILE           row list file, passed through to fast.sh
#                                  (default: fast_row_list.txt)
#   -c, --channel-list FILE       channel list file, passed through to superfast.sh
#                                  (default: superfast_channel_list.txt)

source $MAS_SCRIPT/mas_library.bash

SCRIPT_NAME=$(basename "$0")
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"
SCRIPT_FULL_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_FULL_PATH")

####################################################################
# parse arguments
####################################################################

type=""
run="0"
overwrite="false"
configprefix="config"
max_cols=16
max_rows=41
tes_bias_list="$SCRIPT_DIR/tes_bias_list.txt"
rowlens=119
row_list="$SCRIPT_DIR/fast_row_list.txt"
channel_list="$SCRIPT_DIR/superfast_channel_list.txt"

opts=$(getopt -o R:C:b:l:r:c: \
    --long type:,run:,overwrite,configprefix:,max-cols:,max-rows:,tes-bias-list:,rowlens:,row-list:,channel-list: \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        --type)              type="$2"; shift 2 ;;
        -R|--run)             run="$2"; shift 2 ;;
        --overwrite)          overwrite="true"; shift ;;
        -C|--configprefix)    configprefix="$2"; shift 2 ;;
        --max-cols)           max_cols="$2"; shift 2 ;;
        --max-rows)           max_rows="$2"; shift 2 ;;
        -b|--tes-bias-list)   tes_bias_list="$2"; shift 2 ;;
        -l|--rowlens)         rowlens="$2"; shift 2 ;;
        -r|--row-list)        row_list="$2"; shift 2 ;;
        -c|--channel-list)    channel_list="$2"; shift 2 ;;
        --)                   shift; break ;;
        *)                    echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$type" ]; then
    echo "Error: --type is required (comma-separated list of n, f, s)"
    exit 1
fi
IFS=',' read -ra type_arr <<< "$type"
for t in "${type_arr[@]}"; do
    case "$t" in
        n|f|s) ;;
        *)
            echo "Error: invalid --type entry '$t' -- must be n, f, or s"
            exit 1
            ;;
    esac
done

if [ ! -f "$tes_bias_list" ]; then
    echo "Error: tes_bias list file not found: $tes_bias_list"
    exit 1
fi

####################################################################
# resolve output directory: $MAS_DATA/master_run<RUN>/
####################################################################

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

# Archive this script, the tes_bias list, and config files; log all output.
cp "$SCRIPT_FULL_PATH" "$dir/$SCRIPT_NAME"
cp "$tes_bias_list" "$dir/tes_bias_list.txt"
exec > >(tee -a "$dir/${SCRIPT_NAME_NO_EXT}.log") 2>&1
echo "=== $(date) starting $SCRIPT_NAME --type ${type_arr[*]} ==="

####################################################################
# initial set up, and archiving config stuff
####################################################################

mas_param set tes_bias_do_reconfig 0
mas_param set config_sync 0
row_deselect_args=$(printf '0 %.0s' $(seq 1 $max_rows))
mas_param set row_deselect $row_deselect_args
mce_make_config
mce_reconfig

cp $MAS_DATA/experiment.cfg $dir/experiment.cfg
configs=("$MAS_DATA"/"$configprefix"*)
if [ "${#configs[@]}" -ne 1 ]; then
    echo "Error: expected exactly one config file in $MAS_DATA"
    printf 'Found:\n'
    printf '  %s\n' "${configs[@]}"
    printf 'Please specify a unique configprefix.\n'
    exit 1
fi
cp "${configs[0]}" "$dir/"

####################################################################
# read tes_bias sweep (line 1) and fixed bias columns (line 2)
####################################################################

tes_bias_values=$(sed -n '1p' "$tes_bias_list")
bias_col_list=$(sed -n '2p' "$tes_bias_list")

declare -A bias_col_set=()
for col in $bias_col_list; do
    bias_col_set[$col]=1
done

####################################################################
# START DATA ACQUISITION
# step tes_bias from high to low; detectors are assumed already
# unlatched and biased into the transition
####################################################################

for tbias in $tes_bias_values
do
    echo "tes_bias="$tbias
    biasdir=$dir'/bias'$tbias
    mkdir -p "$biasdir"

    bias_args=""
    for ((i=0; i<16; i++)); do
        if [ -n "${bias_col_set[$i]}" ]; then
            bias_args="$bias_args $tbias"
        else
            bias_args="$bias_args 0"
        fi
    done

    echo "bias and settle for 20s"
    bias_tess $bias_args
    sleep 20

    for t in "${type_arr[@]}"; do
        case "$t" in
            n)
                sleep 1
                mce_reconfig
                sleep 1
                "$SCRIPT_DIR/normal_dm10.sh" --dir "$biasdir" --rowlens "$rowlens"

                sleep 1
                mce_reconfig
                sleep 1
                "$SCRIPT_DIR/normal_dm1.sh" --dir "$biasdir" --rowlens "$rowlens"
                ;;
            f)
                sleep 1
                mce_reconfig
                sleep 1
                "$SCRIPT_DIR/fast.sh" --dir "$biasdir" --rowlens "$rowlens" --row-list "$row_list"
                ;;
            s)
                sleep 1
                mce_reconfig
                sleep 1
                "$SCRIPT_DIR/superfast.sh" --dir "$biasdir" --channel-list "$channel_list"
                ;;
        esac
    done
done

mce_reconfig