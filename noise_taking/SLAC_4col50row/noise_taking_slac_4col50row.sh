#!/bin/bash
#
# Master noise-taking script for BA module I6. Owns whole-run MCE state
# (initial reconfig, tes_bias sweep, per-bias-step reconfig, row_len/
# sample_dly/filter sweep) and dispatches to the standalone data-taking
# sub-scripts (normal_dm10.sh, normal_dm1.sh, fast.sh, superfast.sh) for
# whichever --type(s) of noise are requested, at every bias step.
#
# Detectors are assumed to already be unlatched and biased into the
# transition before this one runs (same assumption as
# noise_normal_fast_rowlen_ba_i6.sh / noise_superfast_ba_i6.sh) -- this
# script steps tes_bias down from high to low without ever latching. If
# --unlatch-bias is given, this script does that initial unlatch step
# itself (bias_tess at --unlatch-bias, settle for --unlatch-pause) before
# starting the tes_bias sweep; otherwise a separate script is assumed to
# have already done it.
#
# SF - 2023-01-21
# SF, BS - 2023-11-24 added norm noise and modified rows/cols/biases for L4 
# CZ, RS - 2026-01-02 adapted for pickle ba150 L0
# RS - 2026-08-19 reformatted; 
# TBD: obtain parameters from config file instead of command line;
# TBD: include all parameters in sub scripts (normal_dm10.sh, normal_dm1.sh, 
#      fast.sh, superfast.sh)
#
# Usage: noise_taking_ba_i6.sh --type TYPE[,TYPE...] [OPTIONS]
#   --type TYPE[,TYPE...]        required: comma-separated list of one or more of
#                                  n10 (normal_dm10), n1 (normal_dm1), f (fast),
#                                  s (superfast), e.g. "n10", "n10,n1", "f,s", or
#                                  "n10,n1,f,s". At each bias step, n10/n1/f each
#                                  run once per row_len in --rowlens (n10 runs
#                                  normal_dm10.sh; n1 runs normal_dm1.sh; f runs
#                                  fast.sh); s runs superfast.sh once per bias step,
#                                  after the row_len sweep, at its own fixed row_len
#                                  (regardless of where "s" appears in --type).
#   -R, --run RUN                output run extension (default: 0)
#   --overwrite                   allow overwriting an existing basedir
#   -C, --configprefix PFX       config file prefix (default: config)
#   --max-rows N                   total number of rows (default: 41)
#   -b, --tes-bias-list FILE     text file with the tes_bias sweep (line 1) and
#                                  fixed bias columns (line 2) (default:
#                                  tes_bias_list.txt)
#   --unlatch-bias BIAS          optional tes_bias value to unlatch at the start
#   --unlatch-pause SECONDS      optional pause after unlatching (default: 60)
#   -p, --bias-pause SECONDS     optional pause after each bias step (default: 600)
#   -l, --rowlens LIST            comma-separated row_len values to sweep. For each,
#                                  the master sets row_len/sample_dly/filter once, then
#                                  runs the requested type(s) at that row_len (default: 119)
#   -f, --f-cutoff F               Butterworth filter cutoff frequency in Hz (default: 75)
#   -r, --row-list FILE           row list file, passed through to fast.sh
#                                  (default: fast_row_list.txt)
#   -c, --channel-list FILE       channel list file, passed through to superfast.sh
#                                  (default: superfast_channel_list.txt)
#   -n, --nsamp N_NORMAL,N_FAST,N_SUPERFAST
#                                  samples-per-acquisition overrides: first value applies
#                                  to normal_dm10.sh and normal_dm1.sh (shared), second to
#                                  fast.sh, third to superfast.sh. Leave a slot blank (e.g.
#                                  "6800,,4000000") to keep that sub-script's own default;
#                                  omit --nsamp entirely to use all defaults. See
#                                  normal_dm10.sh/normal_dm1.sh/fast.sh/superfast.sh usage
#                                  for their individual defaults.
#
# Examples:
#   # Fast only, quick smoke test: single bias, single row_len, small nsamp,
#   # small row list. Only the "fast" slot is set (middle of the 3); normal
#   # and superfast slots are blank/unused since --type is f-only anyway.
#   ./noise_taking_ba_i6.sh --type f --tes-bias-list tes_bias_list_test.txt \
#       --rowlens 119 --row-list fast_row_list_test.txt --nsamp ,1000, --overwrite
#
#   # Normal only, DM10 + DM1 together, quick smoke test.
#   ./noise_taking_ba_i6.sh --type n10,n1 --tes-bias-list tes_bias_list_test.txt \
#       --rowlens 119 --nsamp 100 --overwrite
#
#   # Normal, DM10 only.
#   ./noise_taking_ba_i6.sh --type n10 --tes-bias-list tes_bias_list_test.txt \
#       --rowlens 119 --nsamp 100 --overwrite
#
#   # Superfast only, quick smoke test: small channel list, reduced nsamp.
#   ./noise_taking_ba_i6.sh --type s --tes-bias-list tes_bias_list_test.txt \
#       --channel-list superfast_channel_list_test.txt --nsamp ,,40000 --overwrite
#
#   # All four types together, quick smoke test at a single bias: small
#   # nsamp for all three slots (normal, fast, superfast).
#   ./noise_taking_ba_i6.sh --type n10,n1,f,s --tes-bias-list tes_bias_list_test.txt \
#       --rowlens 119 --row-list fast_row_list_test.txt \
#       --channel-list superfast_channel_list_test.txt --nsamp 100,1000,40000 --overwrite
#
#   # Multiple row_lens: n10/n1/f each run once per row_len listed (superfast
#   # is unaffected, since it uses its own fixed row_len). Only the fast
#   # slot is overridden; normal keeps its own default (blank first slot).
#   ./noise_taking_ba_i6.sh --type n10,n1,f --tes-bias-list tes_bias_list_test.txt \
#       --rowlens 119,99,79,59 --row-list fast_row_list_test.txt \
#       --nsamp ,1000, --overwrite
#
#   # Production run: all four types, full bias sweep, full row_len sweep,
#   # default nsamp for every sub-script.
#   ./noise_taking_ba_i6.sh --type n10,n1,f,s --run 1

source $MAS_SCRIPT/mas_library.bash

SCRIPT_NAME=$(basename "$0")
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"
SCRIPT_FULL_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_FULL_PATH")

# MCE_TOOLS is normally exported by ~/.bashrc; fall back to deriving it
# from this script's own location if it isn't set (e.g. invoked over a
# non-interactive SSH session that never sourced .bashrc's interactive-only
# export). This script always lives at mce_tools/noise_taking/<module>/, so
# two levels up from SCRIPT_DIR is mce_tools/ regardless of checkout path.
MCE_TOOLS="${MCE_TOOLS:-$(dirname "$(dirname "$SCRIPT_DIR")")}"

####################################################################
# parse arguments
####################################################################

type=""
run="0"
overwrite="false"
configprefix="config"
max_rows=50
tes_bias_list="$SCRIPT_DIR/tes_bias_list.txt"
unlatch_bias=""
unlatch_pause=0
bias_pause=0
rowlens=70
f_cutoff=75
row_list="$SCRIPT_DIR/fast_row_list.txt"
channel_list="$SCRIPT_DIR/superfast_channel_list.txt"
nsamp=""

opts=$(getopt -o R:C:b:l:f:r:c:n:p: \
    --long type:,run:,overwrite,configprefix:,max-rows:,tes-bias-list:,unlatch-bias:,unlatch-pause:,bias-pause:,rowlens:,f-cutoff:,row-list:,channel-list:,nsamp: \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        --type)               type="$2"; shift 2 ;;
        -R|--run)             run="$2"; shift 2 ;;
        --overwrite)          overwrite="true"; shift ;;
        -C|--configprefix)    configprefix="$2"; shift 2 ;;
        --max-rows)           max_rows="$2"; shift 2 ;;
        -b|--tes-bias-list)   tes_bias_list="$2"; shift 2 ;;
        --unlatch-bias)       unlatch_bias="$2"; shift 2 ;;
        --unlatch-pause)      unlatch_pause="$2"; shift 2 ;;
        -p|--bias-pause)      bias_pause="$2"; shift 2 ;;
        -l|--rowlens)         rowlens="$2"; shift 2 ;;
        -f|--f-cutoff)        f_cutoff="$2"; shift 2 ;;
        -r|--row-list)        row_list="$2"; shift 2 ;;
        -c|--channel-list)    channel_list="$2"; shift 2 ;;
        -n|--nsamp)           nsamp="$2"; shift 2 ;;
        --)                   shift; break ;;
        *)                    echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$type" ]; then
    echo "Error: --type is required (comma-separated list of n10, n1, f, s)"
    exit 1
fi
IFS=',' read -ra type_arr <<< "$type"
for t in "${type_arr[@]}"; do
    case "$t" in
        n10|n1|f|s) ;;
        *)
            echo "Error: invalid --type entry '$t' -- must be n10, n1, f, or s"
            exit 1
            ;;
    esac
done

has_type() {
    local want=$1 t
    for t in "${type_arr[@]}"; do
        [ "$t" = "$want" ] && return 0
    done
    return 1
}
do_n10=false; has_type n10 && do_n10=true
do_n1=false; has_type n1 && do_n1=true
do_f=false; has_type f && do_f=true
do_s=false; has_type s && do_s=true

####################################################################
# split --nsamp into per-type overrides: normal (n10+n1), fast, superfast.
# A blank slot (e.g. "6800,,4000000") leaves that sub-script at its own
# built-in default.
####################################################################

nsamp_normal=""
nsamp_fast=""
nsamp_superfast=""
if [ -n "$nsamp" ]; then
    IFS=',' read -ra nsamp_arr <<< "$nsamp,,"
    nsamp_normal="${nsamp_arr[0]}"
    nsamp_fast="${nsamp_arr[1]}"
    nsamp_superfast="${nsamp_arr[2]}"
fi

nsamp_normal_arg=()
[ -n "$nsamp_normal" ] && nsamp_normal_arg=(--nsamp "$nsamp_normal")
nsamp_fast_arg=()
[ -n "$nsamp_fast" ] && nsamp_fast_arg=(--nsamp "$nsamp_fast")
nsamp_superfast_arg=()
[ -n "$nsamp_superfast" ] && nsamp_superfast_arg=(--nsamp "$nsamp_superfast")

if [ ! -f "$tes_bias_list" ]; then
    echo "Error: tes_bias list file not found: $tes_bias_list"
    exit 1
fi

####################################################################
# resolve output directory: $MAS_DATA/<script>_run<RUN>/
#
# dir (and biasdir below) are kept RELATIVE to $MAS_DATA throughout, since
# they're passed as --dir to sub-scripts, which expect a path relative to
# $MAS_DATA (mce_run/acq_config prepend $MAS_DATA themselves). Use
# $MAS_DATA/$dir for the master's own plain filesystem ops.
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
dir=$basedir

# Archive this script, the tes_bias list, and config files; log all output.
cp "$SCRIPT_FULL_PATH" "$MAS_DATA/$dir/$SCRIPT_NAME"
cp "$tes_bias_list" "$MAS_DATA/$dir/tes_bias_list.txt"
exec > >(tee -a "$MAS_DATA/$dir/${SCRIPT_NAME_NO_EXT}.log") 2>&1
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

cp $MAS_DATA/experiment.cfg $MAS_DATA/$dir/experiment.cfg
configs=("$MAS_DATA"/"$configprefix"*)
if [ "${#configs[@]}" -ne 1 ]; then
    echo "Error: expected exactly one config file in $MAS_DATA"
    printf 'Found:\n'
    printf '  %s\n' "${configs[@]}"
    printf 'Please specify a unique configprefix.\n'
    exit 1
fi
cp "${configs[0]}" "$MAS_DATA/$dir/"

####################################################################
# read tes_bias sweep (first data line) and fixed bias columns (second
# data line), skipping comment (#) and blank lines
####################################################################

tes_bias_data=$(grep -v '^\s*#' "$tes_bias_list" | grep -v '^\s*$')
tes_bias_values=$(echo "$tes_bias_data" | sed -n '1p')
bias_col_list=$(echo "$tes_bias_data" | sed -n '2p')

declare -A bias_col_set=()
for col in $bias_col_list; do
    bias_col_set[$col]=1
done

# bias_tess at the given tes_bias, on the fixed columns in bias_col_set,
# then settle for the given number of seconds. Used for both the optional
# initial unlatch step and each bias step in the sweep below.
bias_and_settle() {
    local tbias=$1 pause=$2
    local bias_args="" i
    for ((i=0; i<16; i++)); do
        if [ -n "${bias_col_set[$i]}" ]; then
            bias_args="$bias_args $tbias"
        else
            bias_args="$bias_args 0"
        fi
    done
    bias_tess $bias_args
    sleep $pause
}

#####################################################################
# set up butterworth filter parameters
#####################################################################
BUTTER_SCRIPT="$MCE_TOOLS/python/mce_butter_params.py"

set_butter_filter() {
    local rlen=$1
    local params
    params=$(python $BUTTER_SCRIPT $max_rows $rlen $f_cutoff)
    if [ $? -ne 0 ]; then
        echo "Error: $BUTTER_SCRIPT failed for row_len=$rlen -- aborting" >&2
        exit 1
    fi
    local vals=$(echo $params | tr -d '[],' )
    echo "setting fltr_coeff for row_len=$rlen, f_cutoff=$f_cutoff Hz: $vals"
    mce_cmd -qx wb rca fltr_coeff $vals
}

# reconfig, then set row_len/sample_dly/filter for the given row_len --
# called once before each of normal_dm10/normal_dm1/fast, since all three
# sweep the same row_len list and otherwise would repeat this identically
reconfig_for_rowlen() {
    local rlen=$1
    sleep 1
    mce_reconfig
    sleep 1
    mce_cmd -qx wb sys row_len $rlen
    sleep 1
    mce_cmd -qx wb rca sample_dly $(($rlen-10))
    sleep 1
    set_butter_filter $rlen
}

IFS=',' read -ra rlen_arr <<< "$rowlens"

####################################################################
# DATA ACQUISITION
####################################################################

if [ -n "$unlatch_bias" ]; then
    echo "unlatching at tes_bias=$unlatch_bias"
    bias_and_settle $unlatch_bias $unlatch_pause
fi

for tbias in $tes_bias_values
do
    echo "tes_bias="$tbias
    biasdir=$dir'/bias'$tbias
    mkdir -p "$MAS_DATA/$biasdir"

    echo "bias and settle for ${bias_pause}s"
    bias_and_settle $tbias $bias_pause

    # normal_dm10 (n10), normal_dm1 (n1), and fast (f) sweep row_len;
    # superfast (s) uses its own fixed internal row_len, so it runs once
    # per bias, outside this loop.
    for rlen in "${rlen_arr[@]}"; do
        if $do_n10; then
            reconfig_for_rowlen $rlen
            "$SCRIPT_DIR/normal_dm10.sh" --dir "$biasdir" --rowlen "$rlen" "${nsamp_normal_arg[@]}"
        fi

        if $do_n1; then
            reconfig_for_rowlen $rlen
            "$SCRIPT_DIR/normal_dm1.sh" --dir "$biasdir" --rowlen "$rlen" "${nsamp_normal_arg[@]}"
        fi

        if $do_f; then
            reconfig_for_rowlen $rlen
            "$SCRIPT_DIR/fast.sh" --dir "$biasdir" --rowlen "$rlen" --row-list "$row_list" "${nsamp_fast_arg[@]}"
        fi
    done

    if $do_s; then
        sleep 1
        mce_reconfig
        sleep 1
        "$SCRIPT_DIR/superfast.sh" --dir "$biasdir" --channel-list "$channel_list" "${nsamp_superfast_arg[@]}"
    fi
done

mce_reconfig
mce_status -s > "$MAS_DATA/$dir/mce_status.txt"