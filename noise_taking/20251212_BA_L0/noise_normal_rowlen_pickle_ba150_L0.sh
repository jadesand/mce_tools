#!/bin/bash
#
# This is the script to take normal noise data in superconducting, mid-transition and normal in SLAC Pickle for BA module L0.
# Most of the content has been taken from an old Bicep2 script for the same purpose, and adapted.
#
# SF - 2023-01-21
# SF, BS - 2023-11-24 added norm noise and modified rows/cols/biases for L4 
# CZ, RS - 2026-01-02 adapted for pickle ba150 L0

# Usage: noise_superfast_script_pickle_ba150_L0.sh run configprefix [max_cols] [max_rows] [unlatch_value] [unlatch_bias_mode] [f_cutoff]
#   --overwrite:   allow overwriting existing directory
#   run:           output run extension (default: 0)
#   configprefix:  config file prefix (default: config)
#   max_cols:      total number of columns (16 or 32, default: 16)
#   max_rows:      total number of rows (default: 41)
#   unlatch_value: bias value for unlatching detectors (default: 65535)
#   unlatch_bias_mode: "all" to bias all cols, "half" to bias only first half cols,
#                      "manual" to use hardcoded values (default: all)
#   f_cutoff:      Butterworth filter cutoff frequency in Hz (default: 75)

source $MAS_SCRIPT/mas_library.bash # RS: mostly define some functions

SCRIPT_NAME=$(basename "$0")
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"

SCRIPT_FULL_PATH=$(readlink -f "$0")

# Parse --overwrite flag
overwrite="false"
for arg in "$@"; do
    if [ "$arg" = "--overwrite" ]; then
        overwrite="true"
        shift
        break
    fi
done

run=${1:-"0"}          # Output run_extension (default: 0)
configprefix=${2:-"config"}
max_cols=${3:-16}            # Total number of columns: 16 or 32 (default: 16)
max_rows=${4:-41}            # Total number of rows: 41 (default: 41)
unlatch_value=${5:-65535}    # Unlatching bias value (default: 65535)
unlatch_bias_mode=${6:-"all"}  # "all", "half", or "manual" (default: all)
f_cutoff=${7:-75}               # Butterworth filter cutoff frequency in Hz (default: 75)

BUTTER_SCRIPT=$(dirname "$SCRIPT_FULL_PATH")/mce_butter_params.py

# Set Butterworth filter coefficients for current row_len and f_cutoff
set_butter_filter() {
    local rlen=$1
    local params=$(python $BUTTER_SCRIPT $max_rows $rlen $f_cutoff)
    # params is a list like [b11, b12, b21, b22, k1, k2]
    local vals=$(echo $params | tr -d '[],' )
    echo "setting fltr_coeff for row_len=$rlen, f_cutoff=$f_cutoff Hz: $vals"
    mce_cmd -qx wb rca fltr_coeff $vals
}

basedir=$SCRIPT_NAME_NO_EXT'_run'$run

if [ -d $MAS_DATA/$basedir ]; then
    if [ "$overwrite" != "true" ]; then
        echo "Directory $MAS_DATA/$basedir already exists! Please choose a different run number or use overwrite=true."
        exit 1
    fi
else
    mkdir $MAS_DATA/$basedir
fi

####################################################################
# initial set up, and archiving config and script stuff
####################################################################

# Don't fiddle with tes bias when using mce_reconfig in 'freeze_servo.py'
mas_param set tes_bias_do_reconfig 0
mas_param set config_sync 0
# Build row_deselect args dynamically (max_rows zeros)
row_deselect_args=$(printf '0 %.0s' $(seq 1 $max_rows))
mas_param set row_deselect $row_deselect_args
mce_make_config
mce_reconfig

# Archive scripts and config files
cp "$SCRIPT_FULL_PATH" $MAS_DATA/$basedir/script
cp $MAS_DATA/experiment.cfg $MAS_DATA/$basedir/experiment.cfg
configs=("$MAS_DATA"/"$configprefix"*)
if [ "${#configs[@]}" -ne 1 ]; then
    echo "Error: expected exactly one config file in $MAS_DATA"
    printf 'Found:\n'
    printf '  %s\n' "${configs[@]}"
    printf 'Please specify a unique configprefix.\n'
    exit 1
fi
cp "${configs[0]}" "$MAS_DATA/$basedir/"





####################################################################
# this section has the details for some one-time set ups
####################################################################

#change row, col, biases !!!


####################################################################
# START DATA ACQUISITION
####################################################################

# Unlatching detectors before starting bias scan
# Build unlatch bias command dynamically based on max_cols and unlatch_bias_mode
# unlatch_bias_mode="all": all columns get unlatch_value
# unlatch_bias_mode="half": only first half columns get unlatch_value (rest get 0)
# unlatch_bias_mode="manual": use hardcoded values below
if [ "$unlatch_bias_mode" = "manual" ]; then
    echo "unlatch (manual) for 1s, no tile heater"
    # Edit the line below to set manual bias values:
    #             0     1     2     3     4     5     6     7     8     9    10    11    12    13    14    15
    bias_tess 65535 65535 65535 65535 65535 65535 65535 65535 65535 65535 65535 65535 65535 65535 65535 65535
else
    unlatch_bias_args=""
    for ((i=0; i<max_cols; i++)); do
        if [ "$unlatch_bias_mode" = "half" ] && [ $i -ge $((max_cols / 2)) ]; then
            unlatch_bias_args="$unlatch_bias_args 0"
        else
            unlatch_bias_args="$unlatch_bias_args $unlatch_value"
        fi
    done
    echo "unlatch ($unlatch_value) for 1s, max_cols=$max_cols, unlatch_bias_mode=$unlatch_bias_mode, no tile heater"
    bias_tess $unlatch_bias_args
fi
sleep 1

# start from high bias and step down, assumes detectors have
# already been biased into the transition

# for tbias in 6000 4000 3000 2750 2500 2250 2000 1750 1500 500 0
for tbias in 5000 3000 2500 2000 0 
# for tbias in 5000 2500
do
    echo "tes_bias="$tbias
    dir=$basedir'/bias'$tbias'/'
    if [ ! -d $MAS_DATA/$dir ]; then
        mkdir $MAS_DATA/$dir
    fi

    echo "bias and settle for 30s"
    bias_tess  $tbias 0 0 0 $tbias 0 0 0 0 0 0 0 0 0 0 0

    sleep 30

    sleep 1
    mce_reconfig
    sleep 1

    for rlen in 119 104 89 74 59
    # for rlen in 109 99 79
    do

        ####################################################################
        # normal data noise for all channels at the bias
        ####################################################################

        echo "taking normal, downsampled, noise for all channels at tes_bias="$tbias

        mce_cmd -qx wb sys row_len $rlen
        sleep 1
        mce_cmd -qx wb rca sample_dly $(($rlen-10))
        sleep 1
        set_butter_filter $rlen
        sleep 5

        echo "row_len set to: $(command_reply rb sys row_len)"
        echo "sample_dly set to: $(command_reply rb rca sample_dly)"
        
        if [ "$overwrite" = "true" ]; then
            rm -f $MAS_DATA/$dir'/all_rcs_datamode10_rowlen'$rlen*
        fi

        mce_run $dir'/all_rcs_datamode10_rowlen'$rlen 6800 s # this corresponds to t= #samples/fs (sec)
        # mce_run $dir'/all_rcs_datamode10_rowlen'$rlen 100 s # this corresponds to t= #samples/fs (sec)

        sleep 5
        mce_cmd -qx wb rca data_mode 1
        sleep 5
        
        if [ "$overwrite" = "true" ]; then
            rm -f $MAS_DATA/$dir'/all_rcs_datamode1_rowlen'$rlen*
        fi

        mce_run $dir'/all_rcs_datamode1_rowlen'$rlen 6800 s # this corresponds to t= #samples/fs (sec)
        # mce_run $dir'/all_rcs_datamode1_rowlen'$rlen 100 s # this corresponds to t= #samples/fs (sec)

        sleep 1
        mce_reconfig
        sleep 1

    done
done

mce_reconfig