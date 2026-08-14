#!/bin/bash
#
# This is the script to take superfast noise data and fb_const square wave calibration in SLAC Pickle for BA module L0.
# Most of the content has been taken from an old Bicep2 script for the same purpose, and adapted.
# BA H5 is a one-level module, so there is no chip-select layer (unlike two-level modules).
#
# SF - 2023-01-21
# SF, BS - 2023-11-24 added norm noise and modified rows/cols/biases for L4
# CZ, RS - 2026-01-02 adapted for pickle ba150 L0
# RS - 2026-01-24 adapted for superfast data only

# Usage: noise_superfast_ba_h5.sh [OPTIONS]
#   -c, --channel-list FILE  text file specifying channels to take noise on (format: "tes_bias row col1,col2,...", one line per row, with optional comment lines starting with #)
#   --overwrite              allow overwriting existing directory
#   -r, --run RUN            output run extension (default: 0)
#   -C, --configprefix PFX   config file prefix (default: config)
#   --max-cols N             total number of columns: 16 or 32 (default: 16)
#   --max-rows N             total number of rows (default: 41)
#   -u, --unlatch-value V    bias value for unlatching detectors (default: 65535)
#   -b, --unlatch-bias-mode M  "all", "half", or "manual" (default: all)

source $MAS_SCRIPT/mas_library.bash # RS: mostly define some functions

SCRIPT_NAME=$(basename "$0")
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"
SCRIPT_FULL_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_FULL_PATH")
MCE_TOOLS=$(dirname "$(dirname "$SCRIPT_DIR")")

FREEZE_SCRIPT="$MCE_TOOLS/python/mce_freeze_servo_mux11d.py"

# Default values
channel_list="superfast_list.txt"
overwrite="false"
run="0"
configprefix="config"
max_cols=16
max_rows=41
unlatch_value=65535
unlatch_bias_mode="all"

# Parse keyword arguments with getopt
opts=$(getopt -o c:R:C:u:b: \
    --long channel-list:,overwrite,run:,configprefix:,max-cols:,max-rows:,unlatch-value:,unlatch-bias-mode: \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        -c|--channel-list)      channel_list="$2"; shift 2 ;;
        --overwrite)            overwrite="true"; shift ;;
        -R|--run)                run="$2"; shift 2 ;;
        -C|--configprefix)      configprefix="$2"; shift 2 ;;
        --max-cols)              max_cols="$2"; shift 2 ;;
        --max-rows)              max_rows="$2"; shift 2 ;;
        -u|--unlatch-value)     unlatch_value="$2"; shift 2 ;;
        -b|--unlatch-bias-mode) unlatch_bias_mode="$2"; shift 2 ;;
        --)                     shift; break ;;
        *)                      echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate required arguments
if [ -z "$channel_list" ]; then
    echo "Error: --channel-list is required"
    exit 1
fi
if [ ! -f "$channel_list" ]; then
    echo "Error: channel list file not found: $channel_list"
    exit 1
fi

# Read channel list file (format: "tes_bias row col1,col2,..." per line)
channel_entries=$(grep -v '^\s*#' "$channel_list" | grep -v '^\s*$')

# Pre-pass: build, for each tes_bias, the union of columns read out across
# all its rows, so bias_tess can bias exactly those columns (not just 0 and 4).
declare -A bias_cols
while IFS=' ' read -r tbias row cols; do
    IFS=',' read -ra col_arr <<< "$cols"
    for col in "${col_arr[@]}"; do
        bias_cols[$tbias,$col]=1
    done
done <<< "$channel_entries"

basedir=$SCRIPT_NAME_NO_EXT'_run'$run

if [ -d $MAS_DATA/$basedir ]; then
    if [ "$overwrite" != "true" ]; then
        echo "Directory $MAS_DATA/$basedir already exists! Please choose a different run number or use overwrite=true."
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
cp "$SCRIPT_FULL_PATH" $MAS_DATA/$basedir/noise_superfast_script
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
# SUPERFAST SET UP--> set up the superfast_acq script parameters
####################################################################

row_len=62 	    #98 gives 250kHz, 62 gives 400kHz, 120 gives 200kHz
#for superfast data (raw mode + rectangle mode ) sampling frequency is fs=50e6/(row_len*2)
#(the extra 2 comes from the fact that we set num_rows=2 -- for script stability?--)
ccnumrows=41
ccnumcols=1

datarate=$(( $ccnumrows * $ccnumcols ))
#nsamp = ccnumrows * ccnumcols * fs * t_int
#nsamp = 164000000 # integration time t_int ~ 10s

sampleuse=$(((4000000)/($ccnumrows)/($ccnumcols) ))
# sampleuse=$(((4000)/($ccnumrows)/($ccnumcols) )) # quick check
sampint=$(printf "%.0f\n" "$sampleuse")

samplenum=`command_reply rb rc1 sample_num`
sampledly=$(( $row_len-$samplenum ))

#############################################################
# FB_CONST SQRWAVE SET UP --> set up the fb_const squrewave #
#############################################################

# para=31              #where rc1/rc2 fb_const are physically mapped per mce_status -g
card1=3              #where rc1 fb_const is physically mapped per mce_status -g
card2=4              #where rc2 fb_const is physically mapped per mce_status -g
period=50            #min is 8000/41=195
stepsize=200          #10 is good, keep it linear --> changed to 200 to increase S/N

# Parameters for 10 kHz acquisition during fb_const square wave calibration
fast_ccnumrows=1
fast_rcnumrows=1
fast_datarate=1

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

prev_bias=""
prev_row=""

while IFS=' ' read -r tbias row cols; do
    # --- Execute previously accumulated script if bias or row is changing ---
    if [ "$tbias" != "$prev_bias" ] || [ "$row" != "$prev_row" ]; then
        if [ -n "$prev_row" ] && [ -f "$script" ]; then
            echo "running noise_superfast.scr"
            mce_cmd -iqf $script
            echo "done with noise_superfast.scr"
            cp $script $MAS_DATA/$dir"/noise_superfast.scr.row"$prev_row
        fi
    fi

    # --- Bias-level setup (only when tes_bias changes) ---
    if [ "$tbias" != "$prev_bias" ]; then
        echo "tes_bias="$tbias

        dir=$basedir'/bias'$tbias'/'
        if [ ! -d $MAS_DATA/$dir ]; then
            mkdir $MAS_DATA/$dir
        fi

        echo "bias and settle for 30s"
        bias_args=""
        for ((i=0; i<16; i++)); do
            if [ -n "${bias_cols[$tbias,$i]}" ]; then
                bias_args="$bias_args $tbias"
            else
                bias_args="$bias_args 0"
            fi
        done
        bias_tess $bias_args

        sleep 30

        prev_bias="$tbias"
        prev_row=""  # force row setup on bias change
    fi

    # --- Row-level setup (only when row changes within a bias) ---
    if [ "$row" != "$prev_row" ]; then

        ####################################################################
        # freeze the servo on a single row, go open loop, take error data (mode=0)
        #
        # from here on start writing mce_cmd writes to a script for all cols
        # in the row of interest, then after accumulating run the script
        ####################################################################
        sleep 1
        mce_reconfig  # get back to normal state to freeze the servo
        sleep 1

        python $FREEZE_SCRIPT --row $row sq1

        sleep 2
        fb_val=(`command_reply rb sq1 fb_const`)
        echo "fb_val="${fb_val[@]}

        script=$MAS_TEMP/noise_superfast.scr
        rm -f $script

        ####################################################################
        # loop quickly over the cols
        # accumulate a single mce_cmd script for all cols in the row.
        # set a few scripting things outside the loop
        ####################################################################
        echo "wb rca readout_row_index 0" >> $script               #open-loop, this should always be 0
        echo "wb rca num_rows_reported 1" >> $script

        prev_row="$row"
    fi

    echo "looping over columns, generating noise_superfast.scr"

    IFS=',' read -ra col_arr <<< "$cols"
    for col in "${col_arr[@]}"; do
        echo 'col='$col
        if [ $col -lt 8 ]; then
            rc=1
            card=$card1        # set up for the fb_const sqrwave
        else
            rc=2
            card=$card2        # set up for the fb_const sqrwave
        fi

        ####################################################################
        # take super-fast noise timestreams: 400kHz, sampling channel of interest (rectangle + raw mode)
        ####################################################################

        filename=$MAS_DATA/$dir'/superfast_row'$row'_col'$col

        echo "wb sys row_len "$row_len >> $script
        echo "wb rca sample_dly "$sampledly >> $script
        echo "wb sys num_rows 2" >> $script  # num_rows: number of rows to be multiplexed.
        echo "wb rca num_rows_reported 1" >> $script
        echo "wb rca num_cols_reported 1" >> $script
        echo "wb cc num_rows_reported "$ccnumrows >> $script
        echo "wb cc num_cols_reported "$ccnumcols >> $script
        echo "wb cc data_rate "$datarate >> $script
        echo "wb rca readout_col_index "$col >> $script

        echo "sleep 10" >> $script  # mce_cmd sleep <microseconds>

        echo "acq_config "$filename" rc"$rc >> $script # acq_config <filename> <readout_card>, configures a single output file to receive MCE frames
        echo "acq_go "$sampint >> $script

        # return mce to default state
        # rca num_rows_reported and cc num_rows_reported were not changed
        echo "wb sys row_len "$def_rowlen >> $script
        echo "wb rca sample_dly "$def_sampdly >> $script
        echo "wb sys num_rows "$def_numrows >> $script
        echo "wb rca num_cols_reported "$def_rcnumcolsrep >> $script
        echo "wb cc num_cols_reported "$def_ccnumcolsrep >> $script
        echo "wb cc data_rate "$def_datarate >> $script
        echo "wb rca readout_col_index "$def_colindex >> $script

        extn=$MAS_DATA/$dir'/calib_row'$row'_col'$col

        echo "fb_const_calib="${fb_val[@]}

        min=$((${fb_val[$col]}-$stepsize))
        max=$((${fb_val[$col]}+$stepsize))
        step=$(($max - $min))

        # set up for fast (10 kHz) acquisition, stay in data_mode 0

        echo "wb cc num_rows_reported "$fast_ccnumrows >> $script
        echo "wb rca num_rows_reported "$fast_rcnumrows >> $script
        echo "wb cc data_rate "$fast_datarate >> $script

        # set up fb const square wave

        echo "acq_config "$extn" rc"$rc >> $script

        for ifb_const in {1..200}; do
            n=$(($ifb_const%2))
            if [ $n -lt 1 ]; then
                echo "wb rca fb_const "$min $min $min $min $min $min $min $min>> $script
            else
                echo "wb rca fb_const "$max $max $max $max $max $max $max $max>> $script
            fi
            echo "sleep 10" >> $script
            echo "acq_go "$period >> $script
        done

        echo "sleep 10" >> $script

        echo "wb cc internal_cmd_mode 0" >> $script  #turn off the sqr wave on fb_const
        echo "wb sq1 fb_const "${fb_val[@]} >> $script  #return to the servo_freeze values

    ####################################################################
    done

done <<< "$channel_entries"

# Run the final accumulated script
if [ -f "$script" ]; then
    echo "running noise_superfast.scr"
    mce_cmd -iqf $script
    echo "done with noise_superfast.scr"

    cp $script $MAS_DATA/$dir"/noise_superfast.scr.row"$prev_row
fi

mce_reconfig
