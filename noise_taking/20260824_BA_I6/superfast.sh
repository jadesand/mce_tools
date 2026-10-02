#!/bin/bash
#
# Take superfast noise data (~400kHz, rectangle + raw mode) and fb_const
# square-wave calibration, for a list of rows and, per row, a list of columns.
#
# Pure data-taking: assumes the MCE is already biased for this run by the
# caller. row_len is fixed for superfast acquisition (not swept), so it is
# set internally rather than passed in. One exception to "no MCE state":
# this script calls mce_reconfig once per row in its own loop, to undo
# num_rows_reported=1 left behind by the previous row's generated .scr --
# that's internal bookkeeping for this script's own loop, not whole-run
# setup, so it stays here rather than being pushed onto the caller.
#
# RS - 2026-08-19 split out of noise_superfast_ba_i6.sh
# RS - 2026-08-25 card1/card2/period/stepsize are now getopt options instead
#      of hardcoded values
#
# Usage: superfast.sh [OPTIONS]
#   -d, --dir DIR              output directory to write into, relative to $MAS_DATA;
#                                 must already exist. Use this when a master script
#                                 has already created a per-bias subfolder.
#   -R, --run RUN               if --dir is not given, self-create and use
#                                 $MAS_DATA/superfast_run<RUN> (default: 0)
#   --overwrite                   if --dir is not given, allow overwriting an
#                                 existing superfast_run<RUN> directory
#   -c, --channel-list FILE    text file specifying rows/columns to loop over
#                                (format: "row col1,col2,...", one line per row,
#                                with optional comment lines starting with #;
#                                default: superfast_channel_list.txt)
#   -n, --nsamp N               total samples to divide across rows/cols for the main
#                                acquisition (sampint = nsamp / ccnumrows / ccnumcols;
#                                default: 4000000)
#   --card1 N                  physical card rc1 fb_const is mapped to, per
#                                mce_status -g (default: 3)
#   --card2 N                  physical card rc2 fb_const is mapped to, per
#                                mce_status -g (default: 4)
#   --period N                  fb_const square-wave half-period, in the units
#                                acq_go takes; minimum is 8000/max_rows (default: 50)
#   --stepsize N                fb_const square-wave step size around the locking
#                                feedback (min +/- stepsize); keep it linear (default: 50)

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

FREEZE_SCRIPT="$MCE_TOOLS/python/mce_freeze_servo_mux11d.py"

####################################################################
# parse arguments
####################################################################

dir=""
run="0"
overwrite="false"
channel_list="$SCRIPT_DIR/superfast_channel_list.txt"
nsamp=4000000
card1=3
card2=4
period=50
stepsize=50

opts=$(getopt -o d:R:c:n: \
    --long dir:,run:,overwrite,channel-list:,nsamp:,card1:,card2:,period:,stepsize: \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        -d|--dir)            dir="$2"; shift 2 ;;
        -R|--run)            run="$2"; shift 2 ;;
        --overwrite)         overwrite="true"; shift ;;
        -c|--channel-list)   channel_list="$2"; shift 2 ;;
        -n|--nsamp)          nsamp="$2"; shift 2 ;;
        --card1)             card1="$2"; shift 2 ;;
        --card2)             card2="$2"; shift 2 ;;
        --period)            period="$2"; shift 2 ;;
        --stepsize)          stepsize="$2"; shift 2 ;;
        --)                  shift; break ;;
        *)                   echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$channel_list" ]; then
    echo "Error: --channel-list is required"
    exit 1
fi
if [ ! -f "$channel_list" ]; then
    echo "Error: channel list file not found: $channel_list"
    exit 1
fi

#####################################################################
# resolve output directory: explicit --dir, or self-create from --run
#
# dir is kept RELATIVE to $MAS_DATA for plain filesystem ops (mkdir, cp,
# tee, redirects). Unlike mce_run, acq_config (embedded in the generated
# .scr) does NOT prepend $MAS_DATA itself, so filename/extn below are
# built as $MAS_DATA/$dir/... (absolute) instead.
#####################################################################

if [ -n "$dir" ]; then
    # Explicit --dir: caller (e.g. a master script) already created this,
    # just use it.
    standalone="false"
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

    # Archive this script and the channel list, and log all output.
    cp "$SCRIPT_FULL_PATH" "$MAS_DATA/$dir/$SCRIPT_NAME"
    cp "$channel_list" "$MAS_DATA/$dir/channel_list.txt"
    exec > >(tee -a "$MAS_DATA/$dir/${SCRIPT_NAME_NO_EXT}.log") 2>&1
    echo "=== $(date) starting $SCRIPT_NAME ==="
fi

# Read channel list file (format: "row col1,col2,..." per line)
channel_entries=$(grep -v '^\s*#' "$channel_list" | grep -v '^\s*$')

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

sampleuse=$((($nsamp)/($ccnumrows)/($ccnumcols) ))
sampint=$(printf "%.0f\n" "$sampleuse")

samplenum=`command_reply rb rc1 sample_num`
sampledly=$(( $row_len-$samplenum ))

#############################################################
# FB_CONST SQRWAVE SET UP --> set up the fb_const squrewave #
# (card1, card2, period, stepsize are set from --card1/--card2/--period/
# --stepsize above)
#############################################################

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
# loop over rows, freeze servo on each, accumulate and run a script
# for all columns of interest on that row
####################################################################

while IFS=' ' read -r row cols; do

    ####################################################################
    # freeze the servo on a single row, go open loop, take error data (mode=0)
    #
    # from here on start writing mce_cmd writes to a script for all cols
    # in the row of interest, then after accumulating run the script
    ####################################################################
    sleep 1
    # get back to normal state (num_rows_reported etc, left at 1 by the
    # previous row's generated .scr) before freezing the servo on this row
    mce_reconfig
    sleep 1

    python $FREEZE_SCRIPT --row $row --keep-tes-bias sq1
    if [ $? -ne 0 ]; then
        echo "Error: $FREEZE_SCRIPT failed for row=$row -- aborting" >&2
        exit 1
    fi

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

    echo "running noise_superfast.scr"
    mce_cmd -iqf $script
    echo "done with noise_superfast.scr"
    cp $script $MAS_DATA/$dir"/noise_superfast.scr.row"$row

done <<< "$channel_entries"

mce_status -s > "$MAS_DATA/$dir/mce_status.txt"
