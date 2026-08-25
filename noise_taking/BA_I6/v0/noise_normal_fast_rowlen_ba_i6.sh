#!/bin/bash
#
# This is the script to take normal and fast noise data in superconducting, mid-transition and normal in SLAC Pickle for BA module L0.
# Most of the content has been taken from an old Bicep2 script for the same purpose, and adapted.
#
# SF - 2023-01-21
# SF, BS - 2023-11-24 added norm noise and modified rows/cols/biases for L4 
# CZ, RS - 2026-01-02 adapted for pickle ba150 L0

# Usage: noise_normal_fast_rowlen_ba_i6.sh [OPTIONS]
#   -t, --tbias-rowlen-list FILE  text file specifying tes_bias, row_len, and (optionally) columns to loop over
#                                  (format: "tbias rowlen1,rowlen2,... [col1,col2,...]", one line per bias,
#                                  with optional comment lines starting with #; if cols is omitted, all
#                                  16 columns are biased; default: normal_fast_tbias_rowlen.txt)
#   --overwrite               allow overwriting existing directory
#   -R, --run RUN            output run extension (default: 0)
#   -C, --configprefix PFX   config file prefix (default: config)
#   --max-cols N              total number of columns: 16 or 32 (default: 16)
#   --max-rows N               total number of rows (default: 41)
#   -u, --unlatch-value V    bias value for unlatching detectors (default: 65535)
#   -b, --unlatch-bias-mode M  "all", "half", or "manual" (default: all)
#   -f, --f-cutoff F           Butterworth filter cutoff frequency in Hz (default: 75)

source $MAS_SCRIPT/mas_library.bash # RS: mostly define some functions

SCRIPT_NAME=$(basename "$0")
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"

SCRIPT_FULL_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_FULL_PATH")

# Default values
tbias_rowlen_list="$SCRIPT_DIR/normal_fast_tbias_rowlen.txt"
overwrite="false"
run="0"
configprefix="config"
max_cols=16
max_rows=41
unlatch_value=65535
unlatch_bias_mode="all"
f_cutoff=75

# Parse keyword arguments with getopt
opts=$(getopt -o t:R:C:u:b:f: \
    --long tbias-rowlen-list:,overwrite,run:,configprefix:,max-cols:,max-rows:,unlatch-value:,unlatch-bias-mode:,f-cutoff: \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        -t|--tbias-rowlen-list) tbias_rowlen_list="$2"; shift 2 ;;
        --overwrite)            overwrite="true"; shift ;;
        -R|--run)                run="$2"; shift 2 ;;
        -C|--configprefix)      configprefix="$2"; shift 2 ;;
        --max-cols)              max_cols="$2"; shift 2 ;;
        --max-rows)              max_rows="$2"; shift 2 ;;
        -u|--unlatch-value)     unlatch_value="$2"; shift 2 ;;
        -b|--unlatch-bias-mode) unlatch_bias_mode="$2"; shift 2 ;;
        -f|--f-cutoff)           f_cutoff="$2"; shift 2 ;;
        --)                     shift; break ;;
        *)                      echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ ! -f "$tbias_rowlen_list" ]; then
    echo "Error: tbias/rowlen list file not found: $tbias_rowlen_list"
    exit 1
fi

# Read tbias/rowlen/cols list file (format: "tbias rowlen1,rowlen2,... [col1,col2,...]" per line)
tbias_rowlen_entries=$(grep -v '^\s*#' "$tbias_rowlen_list" | grep -v '^\s*$')

BUTTER_SCRIPT="$MCE_TOOLS/python/mce_butter_params.py"

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
# FAST SET UP --> set up the fast_acq script parameters and save the commands in a set up script
####################################################################
# Fast data saving rate can't keep up with all 41 rows at once, so fast data
# is taken in chunks of up to 9 rows at a time. One fast.scr is generated per
# row chunk, each setting fast_ccnumrows/fast_rcnumrows/fast_rowindex for that chunk.

fast_datamode=1
fast_datarate=1
fast_rows_per_chunk=9

fast_row_starts=()
fast_row_ends=()
fast_scripts=()
row_start=0
while [ $row_start -lt $max_rows ]; do
    row_end=$((row_start + fast_rows_per_chunk - 1))
    if [ $row_end -ge $max_rows ]; then
        row_end=$((max_rows - 1))
    fi
    fast_row_starts+=($row_start)
    fast_row_ends+=($row_end)

    chunk_numrows=$((row_end - row_start + 1))
    fast_script=$MAS_DATA/$basedir/fast_row${row_start}-${row_end}.scr
    echo "wb rca data_mode "$fast_datamode >> $fast_script
    echo "wb cc num_rows_reported "$chunk_numrows >> $fast_script
    echo "wb rca num_rows_reported "$chunk_numrows >> $fast_script
    echo "wb cc data_rate "$fast_datarate >> $fast_script
    echo "wb rca readout_row_index "$row_start >> $fast_script
    fast_scripts+=("$fast_script")

    row_start=$((row_end + 1))
done

#For fast data we use the operational row_len value, so we don't need to add to the script a cmd to set row_len manually
#The fs for fast data is fs=50e6/(row_len*num_rows*data_rate), so for num_rows=41, row_len=120 --> fs ~ 10kHz

# get and save in variables the default values set up by mce_reconfig

def_rowlen=`command_reply rb sys row_len`
def_sampdly=`command_reply rb rca sample_dly`
def_numrows=`command_reply rb sys num_rows`
def_rcnumcolsrep=`command_reply rb rca num_cols_reported`
def_ccnumcolsrep=`command_reply rb cc num_cols_reported`
def_colindex=`command_reply rb rca readout_col_index`
def_datarate=`command_reply rb cc data_rate`



####################################################################
# START DATA ACQUISITION
####################################################################

# Unlatching detectors before starting bias scan
# Build unlatch bias command dynamically based on max_cols and unlatch_bias_mode
# unlatch_bias_mode="all": all columns get unlatch_value
# unlatch_bias_mode="half": only first half columns get unlatch_value (rest get 0)
# unlatch_bias_mode="manual": use hardcoded values below
# if [ "$unlatch_bias_mode" = "manual" ]; then
#     echo "unlatch (manual) for 30s, no tile heater"
#     # Edit the line below to set manual bias values:
#     #             0     1     2     3     4     5     6     7     8     9    10    11    12    13    14    15
#     bias_tess 65535 65535 65535 65535 65535 65535 65535 65535 65535 65535 65535 65535 65535 65535 65535 65535
# else
#     unlatch_bias_args=""
#     for ((i=0; i<max_cols; i++)); do
#         if [ "$unlatch_bias_mode" = "half" ] && [ $i -ge $((max_cols / 2)) ]; then
#             unlatch_bias_args="$unlatch_bias_args 0"
#         else
#             unlatch_bias_args="$unlatch_bias_args $unlatch_value"
#         fi
#     done
#     echo "unlatch ($unlatch_value) for 30s, max_cols=$max_cols, unlatch_bias_mode=$unlatch_bias_mode, no tile heater"
#     bias_tess $unlatch_bias_args
# fi
# Latching skipped here because detectors will be latched prior to this script being run, and we want to start from high bias and step down.
sleep 1

# start from high bias and step down, assumes detectors have
# already been biased into the transition

while IFS=' ' read -r tbias rowlens cols; do
    IFS=',' read -ra rlen_arr <<< "$rowlens"
    for rlen in "${rlen_arr[@]}"
    do
        echo "setting row_len="$rlen


        sleep 1
        mce_cmd -qx wb sys row_len $rlen
        sleep 1
        mce_cmd -qx wb rca sample_dly $(($rlen-10))
        sleep 1
        set_butter_filter $rlen

        echo "row_len set to: $(command_reply rb sys row_len)"
        echo "sample_dly set to: $(command_reply rb rca sample_dly)"

        echo "tes_bias="$tbias
        dir=$basedir'/bias'$tbias'/'
        if [ ! -d $MAS_DATA/$dir ]; then
            mkdir $MAS_DATA/$dir
        fi

        echo "bias and settle for 20s"
        if [ -n "$cols" ]; then
            IFS=',' read -ra bias_col_arr <<< "$cols"
        else
            bias_col_arr=($(seq 0 15))
        fi
        declare -A bias_col_set=()
        for col in "${bias_col_arr[@]}"; do
            bias_col_set[$col]=1
        done
        bias_args=""
        for ((i=0; i<16; i++)); do
            if [ -n "${bias_col_set[$i]}" ]; then
                bias_args="$bias_args $tbias"
            else
                bias_args="$bias_args 0"
            fi
        done
        bias_tess $bias_args

        sleep 20

        ####################################################################
        # 400Hz standard noise for all channels at the bias
        ####################################################################

        echo "taking normal, downsampled, noise for all channels at tes_bias="$tbias

        sleep 1
        mce_reconfig
        sleep 1
        mce_cmd -qx wb sys row_len $rlen
        sleep 1
        mce_cmd -qx wb rca sample_dly $(($rlen-10))
        sleep 1
        set_butter_filter $rlen
        sleep 1

        mce_run $dir'/all_rcs_datamode10_rowlen'$rlen 6800 s # this corresponds to t= #samples/fs (sec)
        # mce_run $dir'/all_rcs_datamode10_rowlen'$rlen 100 s # this corresponds to t= #samples/fs (sec)

        sleep 1
        mce_cmd -qx wb rca data_mode 1
        sleep 1

        mce_run $dir'/all_rcs_datamode1_rowlen'$rlen 6800 s # this corresponds to t= #samples/fs (sec)
        # mce_run $dir'/all_rcs_datamode1_rowlen'$rlen 100 s # this corresponds to t= #samples/fs (sec)

        sleep 1
        mce_reconfig
        sleep 1
        mce_cmd -qx wb sys row_len $rlen
        sleep 1
        mce_cmd -qx wb rca sample_dly $(($rlen-10))
        sleep 1

        ####################################################################
        # ACQUIRE FAST DATA: ~10kHz, closed loop, unfiltered feedback
        # Data saving rate can't keep up with all rows at once, so this is
        # split into chunks of up to 9 rows, one fast_script/mce_run per chunk
        ####################################################################

        echo "taking fast data"
        mas_param set config_sync 0
        mce_make_config
        mce_reconfig
        sleep 1
        mce_cmd -qx wb sys row_len $rlen
        sleep 1
        mce_cmd -qx wb rca sample_dly $(($rlen-10))
        sleep 1

        for ((chunk_i=0; chunk_i<${#fast_scripts[@]}; chunk_i++)); do
            chunk_start=${fast_row_starts[$chunk_i]}
            chunk_end=${fast_row_ends[$chunk_i]}
            echo "taking fast data for rows $chunk_start-$chunk_end"
            mce_cmd -iqf ${fast_scripts[$chunk_i]}
            sleep 1
            fast_filename=$dir'/fast_rowlen'$rlen'_row'$chunk_start'-'$chunk_end
            mce_run $fast_filename 204000 s  # this corresponds to t= #samples/fs (sec), fs=10 kHz
            # mce_run $fast_filename 20400 s  # this corresponds to t= #samples/fs (sec), fs=10 kHz
            sleep 1
        done

        mce_reconfig  # get back to normal state
        sleep 1
    done
done <<< "$tbias_rowlen_entries"

mce_reconfig