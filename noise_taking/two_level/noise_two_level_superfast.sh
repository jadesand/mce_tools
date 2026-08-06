#!/bin/bash

# This script takes superfast noise data on specified channels, one row at a time, freezing the servo on that row.
# It also takes fb_const square wave calibration data for each channel.
# The script is designed to be run after a two-level tuning has been done, and it uses the experiment.cfg files from the tune for MCE setup.
# The output is organized into a directory structure based on the tune ctime and CS, with separate files for each row and column.   

# Usage: noise_two_level_superfast.sh [OPTIONS]
#   -t, --tune-ctime CTIME   tune ctime (REQUIRED)
#   -c, --channel-list FILE  text file specifying channels to take noise on (format: "CS row col1,col2,...", one line per row, with optional comment lines starting with #)
#   --overwrite              allow overwriting existing directory
#   -r, --run RUN            output run extension (default: 0)
#   -C, --configprefix PFX   config file prefix (default: config)
#   -l, --row-len N          length of each row (default: 62)
#   -u, --unlatch-value V    bias value for unlatching detectors (default: 65535)
#   -b, --unlatch-bias-mode M  "all", "half", or "manual" (default: all)

source $MAS_SCRIPT/mas_library.bash

SCRIPT_NAME=$(basename "$0")
SCRIPT_NAME_NO_EXT="${SCRIPT_NAME%.*}"
SCRIPT_FULL_PATH=$(readlink -f "$0")
SCRIPT_DIR=$(dirname "$SCRIPT_FULL_PATH")
MCE_TOOLS=$(dirname "$(dirname "$SCRIPT_DIR")")

FREEZE_SCRIPT="$MCE_TOOLS/python/mce_freeze_servo_mux11d.py"

# Default values
tune_ctime=""
channel_list="tes_input_shorted.txt"
overwrite="false"
run="0"
configprefix="config"
row_len=62
unlatch_value=65535
unlatch_bias_mode="all"

# Parse keyword arguments with getopt
opts=$(getopt -o t:c:R:C:l:u:b:f: \
    --long tune-ctime:,channel-list:,overwrite,run:,configprefix:,row-len:,unlatch-value:,unlatch-bias-mode:,f-cutoff: \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        -t|--tune-ctime)        tune_ctime="$2"; shift 2 ;;
        -c|--channel-list)      channel_list="$2"; shift 2 ;;
        --overwrite)            overwrite="true"; shift ;;
        -R|--run)               run="$2"; shift 2 ;;
        -C|--configprefix)      configprefix="$2"; shift 2 ;;
        -l|--row-len)           row_len="$2"; shift 2 ;;
        -u|--unlatch-value)     unlatch_value="$2"; shift 2 ;;
        -b|--unlatch-bias-mode) unlatch_bias_mode="$2"; shift 2 ;;
        --)                     shift; break ;;
        *)                      echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate required arguments
if [ -z "$tune_ctime" ]; then
    echo "Error: --tune-ctime is required"
    exit 1
fi
if [ -z "$channel_list" ]; then
    echo "Error: --channel-list is required"
    exit 1
fi
if [ ! -f "$channel_list" ]; then
    echo "Error: channel list file not found: $channel_list"
    exit 1
fi

# Read channel list file (format: "CS row col1,col2,..." per line)
channel_entries=$(grep -v '^\s*#' "$channel_list" | grep -v '^\s*$')

# Define tune directory based on tune_ctime
tune_dir="$MAS_DATA/two_level_$tune_ctime"

# Make directory for this run, checking for existing directory first
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


mce_reconfig
sleep 3
####################################################################
# initial set up, and archiving config and script stuff
####################################################################
mas_param set config_sync 0


####################################################################
# SUPERFAST SET UP--> set up the superfast_acq script parameters
####################################################################

row_len=62 	    #98 gives 250kHz, 62 gives 400kHz, 120 gives 200kHz
#for superfast data (raw mode + rectangle mode ) sampling frequency is fs=50e6/(row_len*2)
#(the extra 2 comes from the fact that we set num_rows=2 -- for script stability?--)
# ccnumrows=11
ccnumrows=50
ccnumcols=1

datarate=$(( $ccnumrows * $ccnumcols ))
#nsamp = ccnumrows * ccnumcols * fs * t_int
#nsamp = 164000000 # integration time t_int ~ 10s

sampleuse=$(((4000000)/($ccnumrows)/($ccnumcols) ))
sampint=$(printf "%.0f\n" "$sampleuse")
# sampint=1000
echo "sampint="$sampint

samplenum=`command_reply rb rc1 sample_num`
sampledly=$(( $row_len-$samplenum ))

#############################################################
# FB_CONST SQRWAVE SET UP --> set up the fb_const squrewave #
#############################################################

# para=31              #where rc1/rc2 fb_const are physically mapped per mce_status -g
# card1=3              #where rc1 fb_const is physically mapped per mce_status -g
# card2=4              #where rc2 fb_const is physically mapped per mce_status -g
period=50            #min is 8000/41=195
stepsize=20          #10 is good, keep it linear --> changed to 200 to increase S/N

# Parameters for 10 kHz acquisition during fb_const square wave calibration
fast_ccnumrows=1
fast_rcnumrows=1
fast_datarate=4

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

# Archive scripts and config files
cp $SCRIPT_FULL_PATH $MAS_DATA/$basedir/script

echo "bias and settle for 1s"
echo "taking superfast noise at tes_bias=0"
bias_tess 0

sleep 1


prev_cs=""
prev_row=""

while IFS=' ' read -r cs row cols; do
    # --- Execute previously accumulated script if CS or row is changing ---
    if [ "$cs" != "$prev_cs" ] || [ "$row" != "$prev_row" ]; then
        if [ -n "$prev_row" ] && [ -f "$script" ]; then
            echo "running noise_superfast.scr"
            mce_cmd -iqf $script
            echo "done with noise_superfast.scr"
            cp $script $MAS_DATA/$basedir/$prev_cs"/noise_superfast.scr.row"$prev_row
        fi
    fi

    # --- CS-level setup (only when CS changes) ---
    if [ "$cs" != "$prev_cs" ]; then
        echo "Processing $cs"

        # Create CS subdirectory in basedir
        mkdir -p "$MAS_DATA/$basedir/$cs"

        # Copy experiment.cfg from tune directory
        cp "$tune_dir/$cs/experiment.cfg" "$MAS_DATA/$basedir/$cs/"

        # Set up MCE for this CS
        sleep 1
        mce_zero_bias > /dev/null 2>&1
        sleep 1
        mce_make_config -x -e "$MAS_DATA/$basedir/$cs/experiment.cfg"
        sleep 1

        prev_cs="$cs"
        prev_row=""  # force row setup on CS change
    fi

    # --- Row-level setup (only when row changes within a CS) ---
    if [ "$row" != "$prev_row" ]; then

        # Re-run mce_make_config to ensure clean MCE state before freezing
        sleep 1
        mce_zero_bias > /dev/null 2>&1
        sleep 1
        mce_make_config -x -e "$MAS_DATA/$basedir/$cs/experiment.cfg"
        sleep 1

        echo "Freezing row $row for $cs"
        ####################################################################
        # freeze the servo on a single row, go open loop, take error data (mode=0)
        #
        # from here on start writing mce_cmd writes to a script for all cols
        # in the row of interest, then after accumulating run the script
        ####################################################################

        python $FREEZE_SCRIPT --row $row sq1
        sleep 1

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
        rc=$(( col / 8 + 1 ))

        ####################################################################
        # take super-fast noise timestreams: 400kHz, sampling channel of interest (rectangle + raw mode)
        ####################################################################

        filename=$MAS_DATA/$basedir/$cs'/superfast_row'$row'_col'$col

        echo "wb sys row_len "$row_len >> $script
        echo "wb rca sample_dly "$sampledly >> $script
        echo "wb sys num_rows 2" >> $script  # num_rows: number of rows to be multiplexed.
        echo "wb rca num_rows_reported 1" >> $script
        echo "wb rca num_cols_reported 1" >> $script
        echo "wb cc num_rows_reported "$ccnumrows >> $script
        echo "wb cc num_cols_reported "$ccnumcols >> $script
        echo "wb cc data_rate "$datarate >> $script
        echo "wb rca readout_col_index "$col >> $script

        echo "sleep 1000" >> $script  # mce_cmd sleep <microseconds>

        echo "acq_config "$filename" rc"$rc >> $script # acq_config <filename> <readout_card>, configures a single output file to receive MCE frames
        echo "acq_go "$sampint >> $script
        echo "sleep 10" >> $script  # mce_cmd sleep <microseconds>

        # return mce to default state
        # rca num_rows_reported and cc num_rows_reported were not changed
        # echo "wb sys row_len "$def_rowlen >> $script
        # echo "wb rca sample_dly "$def_sampdly >> $script
        # echo "wb sys num_rows "$def_numrows >> $script
        # echo "wb rca num_cols_reported "$def_rcnumcolsrep >> $script

        echo "sleep 10" >> $script  # mce_cmd sleep <microseconds>
        extn=$MAS_DATA/$basedir/$cs'/calib_row'$row'_col'$col

        echo "fb_const_calib="${fb_val[@]}

        min=$((${fb_val[$col]}-$stepsize))
        max=$((${fb_val[$col]}+$stepsize))
        step=$(($max - $min))

        # set up for fast (10 kHz) acquisition, stay in data_mode 0
        echo "wb sys row_len "$def_rowlen >> $script
        echo "wb rca sample_dly "$def_sampdly >> $script
        echo "wb sys num_rows "$def_numrows >> $script

        echo "wb cc num_rows_reported "$fast_ccnumrows >> $script
        echo "wb rca num_rows_reported "$fast_rcnumrows >> $script
        echo "wb cc data_rate "$fast_datarate >> $script
        echo "sleep 10" >> $script  # mce_cmd sleep <microseconds>
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

    cp $script $MAS_DATA/$basedir/$prev_cs"/noise_superfast.scr.row"$prev_row
fi
sleep 10