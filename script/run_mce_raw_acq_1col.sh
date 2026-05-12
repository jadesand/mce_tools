#!/bin/bash                                                                     

if [ "$#" -lt "1" ]; then
    echo "Usage:   run_mce_raw_acq_1col <RC> <column> <data file suffix> [ <nsamples> <dirname> ]"
    echo "  RC                is 1,2,3, or 4"
    echo "  column            is 0,...,7"
    echo "  data file suffix  will be appended to the filename"
    echo "  nsamples         number of 50 MHz samples to take (default is 65536)"
    echo "  dirname          folder name under \$MAS_DATA (default: raw_<ctime>, created if needed)"
    exit 1
fi

#[$1==RC]
#[$2==column]
#[#3==data file suffix]
#[#4==nsamples - optional, default 65536]

rc=$1
col=$2
suffix=$3
nsamples=${4:-""}
dirname=${5:-"raw_$(date +%s)"}
mode_flag=${6:-""}

nsamples_arg=""
[ -n "$nsamples" ] && nsamples_arg="-s $nsamples"

mode_arg=""
[ -n "$mode_flag" ] && mode_arg="--${mode_flag//_/-}"

echo "acquiring 50 MHz data on rc${rc} column ${col} ..."
"$(dirname "$0")/mce_raw_acq_1col_dev.sh" \
    -r ${rc} -c ${col} ${nsamples_arg} -S "rc${rc}_c${col}_${suffix}" -d "${dirname}" ${mode_arg}