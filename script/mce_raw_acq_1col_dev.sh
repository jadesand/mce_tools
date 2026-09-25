#!/bin/bash

#initialise environment
if [ ! -x ${MAS_VAR:=/usr/mce/bin/mas_var} ]; then
  echo "Cannot find mas_var.  Set MAS_VAR to the full path to the mas_var binary." >&2
  exit 1
else
  eval $(${MAS_VAR} -s)
fi

source $MAS_SCRIPT/mas_library.bash

SCRIPT_NAME=$(basename "$0")

rc=""
column=""
n_samples=""
suffix=""
dirname=""
do_runfile=1
no_setup=0
no_restore=0

opts=$(getopt -o r:c:s:S:d: \
    --long rc:,col:,nsamples:,suffix:,dirname:,no-runfile,no-setup,no-restore,no-setup-no-restore \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        -r|--rc)                  rc="$2"; shift 2 ;;
        -c|--col)                 column="$2"; shift 2 ;;
        -s|--nsamples)            n_samples="$2"; shift 2 ;;
        -S|--suffix)              suffix="_$2"; shift 2 ;;
        -d|--dirname)             dirname="$2"; shift 2 ;;
        --no-runfile)             do_runfile=0; shift ;;
        --no-setup)               no_setup=1; shift ;;
        --no-restore)             no_restore=1; shift ;;
        --no-setup-no-restore)    no_setup=1; no_restore=1; shift ;;
        --)                       shift; break ;;
        *)                        echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$rc" ] || [ -z "$column" ]; then
    echo "Usage:   $SCRIPT_NAME -r <rc> -c <col> [-s <nsamples>] [-S <suffix>] [-d <dirname>]"
    echo "                      [--no-runfile] [--no-setup] [--no-restore] [--no-setup-no-restore]"
    echo "  -r/--rc          readout card: 1,2,3, or 4"
    echo "  -c/--col         column: 0,...,7"
    echo "  -s/--nsamples    number of 50 MHz samples (default: auto-computed from hardware)"
    echo "  -S/--suffix      appended to output filename"
    echo "  -d/--dirname     folder under \$MAS_DATA (default: raw_<ctime>)"
    echo "  --no-runfile     suppress runfile creation"
    echo "  --no-setup       skip MCE configuration (already in raw mode)"
    echo "  --no-restore     skip restoring MCE state after acquisition"
    echo "  --no-setup-no-restore  skip both setup and restore"
    exit 1
fi

rc_cmd=$rc
[ "$rc_cmd" == "s" ] && rc_cmd="a"

change_num_rows=1
[ -n "$n_samples" ] && change_num_rows=0

if [ -z "$dirname" ]; then
    dirname="raw_$(date +%s)"
fi
mkdir -p "$MAS_DATA/$dirname"

# Check firmware
fw_rev=`command_reply rb rc$rc_cmd fw_rev |cut -d' ' -f1`
case "$fw_rev" in
    0x400000d | 0x400000e | 0x5*)
        ;;
    0x4010007 | 0x4020007 | 0x4030007)
        echo "RC firmware $fw_rev does not support single column raw mode!"
        exit 1
        ;;
    *)
        echo "RC firmware $fw_rev not recognized!  Are you sure it supports raw mode?"
        ;;
esac

ct=`print_ctime`
filename=$MAS_DATA/${dirname}/${ct}_raw${suffix}
runfilename=${filename}.run

num_cols_rep=8

# Always read current state — needed for restore even when setup is skipped
use_sync=`command_reply rb cc use_sync`
use_dv=`command_reply rb cc use_dv`
orig_col_index=`command_reply rb rc$rc_cmd readout_col_index`
orig_data_mode=`command_reply rb rc$rc_cmd data_mode`
num_rows_rep=`command_reply rb cc num_rows_reported`
old_num_rows_rep=$num_rows_rep

if [ "$no_setup" == "0" ]; then
    # Disable sync box and set data_mode — only needed once
    mce_cmd -qX "wb cc use_sync 0" -X "wb cc use_dv 0"
    mce_cmd -q \
        -X "wb rc$rc_cmd data_mode 12"
fi

# readout_col_index must be set every time as it changes per column
mce_cmd -q \
    -X "wb rc$rc_cmd readout_col_index $column" \
    -X "sleep 100000"

# Auto-compute n_samples as the largest multiple of lcm(frame_size, mux_cycle)
# that fits in the 65536-sample hardware buffer, so we never read sentinel
# values (0x80000000) and every dataset ends on a complete row-mux cycle
# (mux_cycle = row_len * num_rows_rep: the number of samples, per column,
# in one full pass through all rows).
if [ "$change_num_rows" == "1" ]; then
    frame_size=$(( num_cols_rep * num_rows_rep ))
    row_len_val=`command_reply rb cc row_len`
    mux_cycle=$(( row_len_val * num_rows_rep ))
    a=$frame_size; b=$mux_cycle
    while [ "$b" -ne 0 ]; do t=$(( a % b )); a=$b; b=$t; done
    lcm=$(( frame_size * mux_cycle / a ))
    n_samples=$(( (65536 / lcm) * lcm ))
    echo "Auto n_samples=$n_samples (frame_size=$frame_size, row_len=$row_len_val, mux_cycle=$mux_cycle, lcm=$lcm)"
fi

# Round to nearest complete readout frame
n_frames=$(( n_samples / (num_cols_rep * num_rows_rep) ))

[ "$n_frames" == 0 ] && echo "Error: frame count is $n_frames" && exit 1

if [ "$do_runfile" == "1" ]; then
    mce_status >> $runfilename
    frameacq_stamp $rc $filename $n_frames >> $runfilename
fi

n_warmup_frames=4
warmup_file=$(mktemp "$MAS_DATA/warmup_XXXXXX")
echo "Warm-up acquisition ($n_warmup_frames frames) ..."
mce_cmd -q \
    -X "acq_config $warmup_file rc$rc" \
    -X "wb rc$rc_cmd captr_raw 1" \
    -X "sleep 10000" \
    -X "acq_go $n_warmup_frames"
rm -f "$warmup_file"

echo "Acquiring raw data to $filename ..."
mce_cmd -q \
    -X "acq_config $filename rc$rc" \
    -X "wb rc$rc_cmd captr_raw 1" \
    -X "sleep 10000" \
    -X "acq_go $n_frames"

if [ "$no_restore" == "0" ]; then
    # Restore sync box settings
    mce_cmd -q -X "wb cc use_sync $use_sync" -X "wb cc use_dv $use_dv"
    [ "$change_num_rows" == "1" ] && \
        mce_cmd -qx wb cc num_rows_reported $old_num_rows_rep

    # Restore data_mode and col_index
    mce_cmd -q \
        -X "wb rc$rc_cmd readout_col_index $orig_col_index" \
        -X "wb rc$rc_cmd data_mode $orig_data_mode"
fi

