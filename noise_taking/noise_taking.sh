#!/bin/bash
#
# Master noise-taking script, config-driven: all module-specific parameters
# (row count, bias sweep, row_len sweep, nsamp, list files, superfast
# settings) come from a config file (see config/*.cfg), so the same script
# serves every module. Owns whole-run MCE state (initial reconfig, tes_bias
# sweep, per-bias-step reconfig, row_len/sample_dly/filter sweep) and
# dispatches to the standalone data-taking sub-scripts (normal_dm10.sh,
# normal_dm1.sh, fast.sh, superfast.sh) for whichever --type(s) of noise are
# requested, at every bias step.
#
# Detectors are assumed to already be unlatched and biased into the
# transition before this one runs (same assumption as
# noise_normal_fast_rowlen_ba_i6.sh / noise_superfast_ba_i6.sh) -- this
# script steps tes_bias down from high to low without ever latching. If
# unlatch_bias is set, this script does that initial unlatch step itself
# (bias_tess at unlatch_bias, settle for unlatch_pause) before starting the
# tes_bias sweep; otherwise a separate script is assumed to have already
# done it.
#
# SF - 2023-01-21
# SF, BS - 2023-11-24 added norm noise and modified rows/cols/biases for L4
# CZ, RS - 2026-01-02 adapted for pickle ba150 L0
# RS - 2026-08-19 reformatted;
# RS - 2026-10-21 parameters from config file (-c) instead of per-module
#      script copies; CLI flags still override. -c is now --config (the
#      channel list moved to --channel-list only)
#
# Usage: noise_taking.sh -c CONFIG [OPTIONS]
#   -c, --config MODULE          required: module config directory (uses its
#                                  noise.cfg), e.g. "20261020_ba_i4", or a .cfg
#                                  file directly; looked up in ./config/ if not
#                                  found as given
#   --type TYPE[,TYPE...]        comma-separated list of one or more of
#                                  n10 (normal_dm10), n1 (normal_dm1), f (fast),
#                                  s (superfast), e.g. "n10", "n10,n1", "f,s", or
#                                  "n10,n1,f,s" (overrides config "types"). At each
#                                  bias step, n10/n1/f each run once per row_len in
#                                  rowlens (n10 runs normal_dm10.sh; n1 runs
#                                  normal_dm1.sh; f runs fast.sh); s runs
#                                  superfast.sh once per bias step, after the
#                                  row_len sweep, at its own fixed row_len
#                                  (regardless of where "s" appears in --type).
#   -R, --run RUN                output run extension (default: 0)
#   --overwrite                   allow overwriting an existing basedir
#
#   The following override the config value of the same name:
#   -C, --configprefix PFX       MCE config file prefix in $MAS_DATA
#   --max-rows N                   total number of rows
#   -b, --tes-bias-list FILE     tes_bias sweep (line 1) and fixed bias columns
#                                  (line 2)
#   --unlatch-bias BIAS          tes_bias value to unlatch at the start
#   --unlatch-pause SECONDS      pause after unlatching
#   -p, --bias-pause SECONDS     pause after each bias step
#   -l, --rowlens LIST            comma-separated row_len values to sweep. For each,
#                                  the master sets row_len/sample_dly/filter once, then
#                                  runs the requested type(s) at that row_len
#   -f, --f-cutoff F               Butterworth filter cutoff frequency in Hz
#   -r, --row-list FILE           row list file, passed through to fast.sh
#   --channel-list FILE           channel list file, passed through to superfast.sh
#   -n, --nsamp N_NORMAL,N_FAST,N_SUPERFAST
#                                  samples-per-acquisition overrides: first value applies
#                                  to normal_dm10.sh and normal_dm1.sh (shared), second to
#                                  fast.sh, third to superfast.sh. Leave a slot blank (e.g.
#                                  "6800,,4000000") to keep that slot's config value.
#
#   List files given on the command line are looked up as given, then in
#   the config's own list directory (e.g. config/20261020_ba_i4/), so
#   "--row-list fast_row_list_test.txt" finds the module's test list.
#
# Examples:
#   # Fast only, quick smoke test: single bias, single row_len, small nsamp,
#   # small row list. Only the "fast" slot is set (middle of the 3).
#   ./noise_taking.sh -c 20261020_ba_i4 --type f --tes-bias-list tes_bias_list_test.txt \
#       --rowlens 119 --row-list fast_row_list_test.txt --nsamp ,1000, --overwrite
#
#   # Normal only, DM10 + DM1 together, quick smoke test.
#   ./noise_taking.sh -c 20261020_ba_i4 --type n10,n1 --tes-bias-list tes_bias_list_test.txt \
#       --rowlens 119 --nsamp 100 --overwrite
#
#   # Superfast only, quick smoke test: small channel list, reduced nsamp.
#   ./noise_taking.sh -c 20261020_ba_i4 --type s --tes-bias-list tes_bias_list_test.txt \
#       --channel-list superfast_channel_list_test.txt --nsamp ,,40000 --overwrite
#
#   # All four types together, quick smoke test at a single bias.
#   ./noise_taking.sh -c 20261020_ba_i4 --type n10,n1,f,s --tes-bias-list tes_bias_list_test.txt \
#       --rowlens 119 --row-list fast_row_list_test.txt \
#       --channel-list superfast_channel_list_test.txt --nsamp 100,1000,40000 --overwrite
#
#   # Production run: everything as in the config.
#   ./noise_taking.sh -c 20261020_ba_i4 --run 1

source $MAS_SCRIPT/mas_library.bash

SCRIPT_NAME=$(basename "$0")
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"
SCRIPT_FULL_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_FULL_PATH")

# MCE_TOOLS is normally exported by ~/.bashrc; fall back to deriving it
# from this script's own location if it isn't set (e.g. invoked over a
# non-interactive SSH session that never sourced .bashrc's interactive-only
# export). This script lives at mce_tools/noise_taking/, so one level
# up from SCRIPT_DIR is mce_tools/ regardless of checkout path.
MCE_TOOLS="${MCE_TOOLS:-$(dirname "$SCRIPT_DIR")}"

####################################################################
# parse arguments: find the config first, source it, then apply the
# remaining flags on top so they override config values
####################################################################

opts=$(getopt -o c:R:C:b:l:f:r:n:p: \
    --long config:,type:,run:,overwrite,configprefix:,max-rows:,tes-bias-list:,unlatch-bias:,unlatch-pause:,bias-pause:,rowlens:,f-cutoff:,row-list:,channel-list:,nsamp: \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

config=""
args=("$@")
while true; do
    case "$1" in
        -c|--config)    config="$2"; shift 2 ;;
        --)             break ;;
        *)              shift ;;
    esac
done

if [ -z "$config" ]; then
    echo "Error: -c/--config <module> is required"
    exit 1
fi
if [ ! -e "$config" ] && [ -e "$SCRIPT_DIR/config/$config" ]; then
    config="$SCRIPT_DIR/config/$config"
fi
# a module directory means its noise.cfg
if [ -d "$config" ]; then
    config="${config%/}/noise.cfg"
fi
if [ ! -f "$config" ]; then
    echo "Error: config file '$config' not found"
    exit 1
fi
config=$(readlink -f "$config")
config_dir=$(dirname "$config")

# Defaults, in case the config file omits them
tag="noise"
types=""
max_rows=41
n_bias_lines=""
configprefix="config"
tes_bias_list="tes_bias_list.txt"
row_list="fast_row_list.txt"
channel_list="superfast_channel_list.txt"
unlatch_bias=""
unlatch_pause=2
bias_pause=30
rowlens=89
f_cutoff=75
nsamp_normal=2300
nsamp_fast=204000
nsamp_superfast=4000000
superfast_row_len=62
superfast_ccnumrows=41
superfast_period=50
superfast_stepsize=50
superfast_ac2_cs=0

# shellcheck disable=SC1090
source "$config"

# config list paths are relative to the config file's directory
for v in tes_bias_list row_list channel_list; do
    [[ "${!v}" = /* ]] || printf -v "$v" '%s' "$config_dir/${!v}"
done
# the module's own list directory, for resolving CLI list overrides
list_dir=$(dirname "$tes_bias_list")

# CLI list paths: as given, else in the module's list directory
resolve_list() {
    if [ -f "$1" ] || [ ! -f "$list_dir/$1" ]; then
        echo "$1"
    else
        echo "$list_dir/$1"
    fi
}

run="0"
overwrite="false"
nsamp=""

set -- "${args[@]}"
while true; do
    case "$1" in
        -c|--config)          shift 2 ;;
        --type)               types="$2"; shift 2 ;;
        -R|--run)             run="$2"; shift 2 ;;
        --overwrite)          overwrite="true"; shift ;;
        -C|--configprefix)    configprefix="$2"; shift 2 ;;
        --max-rows)           max_rows="$2"; shift 2 ;;
        -b|--tes-bias-list)   tes_bias_list=$(resolve_list "$2"); shift 2 ;;
        --unlatch-bias)       unlatch_bias="$2"; shift 2 ;;
        --unlatch-pause)      unlatch_pause="$2"; shift 2 ;;
        -p|--bias-pause)      bias_pause="$2"; shift 2 ;;
        -l|--rowlens)         rowlens="$2"; shift 2 ;;
        -f|--f-cutoff)        f_cutoff="$2"; shift 2 ;;
        -r|--row-list)        row_list=$(resolve_list "$2"); shift 2 ;;
        --channel-list)       channel_list=$(resolve_list "$2"); shift 2 ;;
        -n|--nsamp)           nsamp="$2"; shift 2 ;;
        --)                   shift; break ;;
        *)                    echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$types" ]; then
    echo "Error: no noise type given -- set types in the config or pass --type (comma-separated list of n10, n1, f, s)"
    exit 1
fi
IFS=',' read -ra type_arr <<< "$types"
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
# A blank slot (e.g. "6800,,4000000") keeps that slot's config value.
####################################################################

if [ -n "$nsamp" ]; then
    IFS=',' read -ra nsamp_arr <<< "$nsamp,,"
    [ -n "${nsamp_arr[0]}" ] && nsamp_normal="${nsamp_arr[0]}"
    [ -n "${nsamp_arr[1]}" ] && nsamp_fast="${nsamp_arr[1]}"
    [ -n "${nsamp_arr[2]}" ] && nsamp_superfast="${nsamp_arr[2]}"
fi

if [ ! -f "$tes_bias_list" ]; then
    echo "Error: tes_bias list file not found: $tes_bias_list"
    exit 1
fi
if $do_f && [ ! -f "$row_list" ]; then
    echo "Error: row list file not found: $row_list"
    exit 1
fi
if $do_s && [ ! -f "$channel_list" ]; then
    echo "Error: channel list file not found: $channel_list"
    exit 1
fi

####################################################################
# resolve output directory: $MAS_DATA/noise_taking_<tag>_run<RUN>/
#
# dir (and biasdir below) are kept RELATIVE to $MAS_DATA throughout, since
# they're passed as --dir to sub-scripts, which expect a path relative to
# $MAS_DATA (mce_run/acq_config prepend $MAS_DATA themselves). Use
# $MAS_DATA/$dir for the master's own plain filesystem ops.
####################################################################

basedir=$SCRIPT_NAME_NO_EXT'_'$tag'_run'$run
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

# Archive the scripts (shared across modules, so they may change between
# runs), the config, the list files in use, and config files; log all output.
cp "$SCRIPT_FULL_PATH" "$MAS_DATA/$dir/$SCRIPT_NAME"
cp "$SCRIPT_DIR/normal_dm10.sh" "$SCRIPT_DIR/normal_dm1.sh" "$SCRIPT_DIR/fast.sh" "$SCRIPT_DIR/superfast.sh" "$MAS_DATA/$dir/"
cp "$config" "$MAS_DATA/$dir/"
cp "$tes_bias_list" "$MAS_DATA/$dir/tes_bias_list.txt"
$do_f && cp "$row_list" "$MAS_DATA/$dir/row_list.txt"
$do_s && cp "$channel_list" "$MAS_DATA/$dir/channel_list.txt"
exec > >(tee -a "$MAS_DATA/$dir/${SCRIPT_NAME_NO_EXT}.log") 2>&1
echo "=== $(date) starting $SCRIPT_NAME -c $(basename "$config") --type ${type_arr[*]} ==="

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

# number of tes bias lines: from the config if set, otherwise read from the
# MCE (same way bias_tess does). bias_tess requires exactly this many values.
if [ -z "$n_bias_lines" ]; then
    n_bias_lines=$(command_reply rb tes bias | wc -w)
    if [ "$n_bias_lines" -lt 1 ]; then
        echo "Error: could not read tes bias line count from MCE"
        exit 1
    fi
fi

declare -A bias_col_set=()
for col in $bias_col_list; do
    if [ "$col" -lt 0 ] || [ "$col" -ge $n_bias_lines ]; then
        echo "Error: bias column $col in $tes_bias_list is outside 0-$((n_bias_lines-1))"
        exit 1
    fi
    bias_col_set[$col]=1
done

# bias_tess at the given tes_bias, on the fixed columns in bias_col_set,
# then settle for the given number of seconds. Used for both the optional
# initial unlatch step and each bias step in the sweep below.
bias_and_settle() {
    local tbias=$1 pause=$2
    local bias_args="" i
    for ((i=0; i<n_bias_lines; i++)); do
        if [ -n "${bias_col_set[$i]}" ]; then
            bias_args="$bias_args $tbias"
        else
            bias_args="$bias_args 0"
        fi
    done
    echo "bias_args=($bias_args)"
    bias_tess $bias_args
    if [ $? -ne 0 ]; then
        echo "Error: bias_tess failed at tes_bias=$tbias -- aborting" >&2
        exit 1
    fi
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
    echo "unlatching at tes_bias=$unlatch_bias for ${unlatch_pause}s"
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
    # superfast (s) uses its own fixed row_len, so it runs once per bias,
    # outside this loop.
    for rlen in "${rlen_arr[@]}"; do
        if $do_n10; then
            reconfig_for_rowlen $rlen
            "$SCRIPT_DIR/normal_dm10.sh" --dir "$biasdir" --rowlen "$rlen" --nsamp "$nsamp_normal"
        fi

        if $do_n1; then
            reconfig_for_rowlen $rlen
            "$SCRIPT_DIR/normal_dm1.sh" --dir "$biasdir" --rowlen "$rlen" --nsamp "$nsamp_normal"
        fi

        if $do_f; then
            reconfig_for_rowlen $rlen
            "$SCRIPT_DIR/fast.sh" --dir "$biasdir" --rowlen "$rlen" --row-list "$row_list" --nsamp "$nsamp_fast"
        fi
    done

    if $do_s; then
        sleep 1
        mce_reconfig
        sleep 1
        "$SCRIPT_DIR/superfast.sh" --dir "$biasdir" --channel-list "$channel_list" \
            --nsamp "$nsamp_superfast" --row-len "$superfast_row_len" \
            --ccnumrows "$superfast_ccnumrows" --period "$superfast_period" \
            --stepsize "$superfast_stepsize" --ac2-cs "$superfast_ac2_cs"
    fi
done

mce_reconfig
mce_status -s > "$MAS_DATA/$dir/mce_status.txt"
