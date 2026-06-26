#!/bin/bash

# 20260116 copied from b3tower3:/home/bicep3/shawn/mce_scripts/go_raw_all.sh

SCRIPT_NAME=$(basename "$0")
FREEZE_SCRIPT="/home/mce/rshi/mce_scripts/python/mce_freeze_servo_mux11d.py"

ndatasets=1
columns=(0 1 2 3 4 5 6 7)
rcs=(1 2)
# columns=(0 1)
# rcs=(1)
nsamples=""
freeze_stage=""
row=0

opts=$(getopt -o n:c:R:s:f:r: \
    --long ndatasets:,col:,rcs:,nsamples:,freeze-stage:,row: \
    -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then echo "Error parsing options"; exit 1; fi
eval set -- "$opts"

while true; do
    case "$1" in
        -n|--ndatasets)     ndatasets="$2"; shift 2 ;;
        -c|--col)           IFS=',' read -r -a columns <<< "$2"; shift 2 ;;
        -R|--rcs)           IFS=',' read -r -a rcs     <<< "$2"; shift 2 ;;
        -s|--nsamples)      nsamples="$2"; shift 2 ;;
        -f|--freeze-stage)  freeze_stage="$2"; shift 2 ;;
        -r|--row)           row="$2"; shift 2 ;;
        --)                 shift; break ;;
        *)                  echo "Unknown option: $1"; exit 1 ;;
    esac
done

CTIME_FOR_LOGFILE=$(date +%s)
dirname=raw_${CTIME_FOR_LOGFILE}
mkdir -p "$MAS_DATA/$dirname"

LOGFILE=$MAS_DATA/$dirname/log.txt
echo "OUTFILE=${LOGFILE}"

echo "columns=(${columns[@]})"
echo "rcs=(${rcs[@]})"

# log header
echo -e "tune\trc_fpga_temp\trc_card_temp\trc_card_id\trc_card_type\trc_slot_id\trc_fw_rev\trc\tcol\tdatedir\tdata">>${LOGFILE}
for rc in "${rcs[@]}";
do
    MCE_OUTPUT=$(mce_status -s)
    CARD_ID=`echo "$MCE_OUTPUT" | grep rc${rc} | grep card_id | awk '{print $4}'`
    CARD_TYPE=`echo "$MCE_OUTPUT" | grep rc${rc} | grep card_type | awk '{print $4}'`
    SLOT_ID=`echo "$MCE_OUTPUT" | grep rc${rc} | grep slot_id | awk '{print $4}'`
    FW_REV=`echo "$MCE_OUTPUT" | grep rc${rc} | grep fw_rev | awk '{print $4}'`

    if [[ -n "$freeze_stage" ]]; then
        echo "Freezing servo for row=$row, stage=$freeze_stage..."
        if [[ "$freeze_stage" == "preamp" ]] || [[ "$freeze_stage" == "sa" ]]; then
            auto_setup --rc=$rc --last-stage=sa_ramp
        else
            auto_setup --rc=$rc --last-stage=sq1_ramp
        fi
        sleep 1
        python "$FREEZE_SCRIPT" --row "$row" $freeze_stage
    fi
    
    for idx in `seq 1 ${ndatasets}`;
    do
        for ((col=0;col<${#columns[@]};col+=1)); do
            suffix="${idx}"
            is_first=$(( idx == 1 && col == 0 ))
            is_last=$(( idx == ndatasets && col == ${#columns[@]} - 1 ))
            if   [ "$is_first" == "1" ] && [ "$is_last" == "1" ]; then
                mode_flag=""                   # only dataset: full setup and restore
            elif [ "$is_first" == "1" ]; then
                mode_flag="no_restore"         # first of many: setup, no restore
            elif [ "$is_last" == "1" ]; then
                mode_flag="no_setup"           # last of many: no setup, restore
            else
                mode_flag="no_setup_no_restore" # middle: skip both
            fi
            "$(dirname "$0")/run_mce_raw_acq_1col.sh" ${rc} ${columns[$col]} ${suffix} "${nsamples}" "${dirname}" "${mode_flag}"

            # RC info to log
            FPGA_TEMP=$(mce_status -s | grep "rc${rc}" | grep fpga_temp | awk '{print $4}')
            CARD_TEMP=$(mce_status -s | grep "rc${rc}" | grep card_temp | awk '{print $4}')

            RCINFO="$FPGA_TEMP\t$CARD_TEMP\t$CARD_ID\t$CARD_TYPE\t$SLOT_ID\t$FW_REV"
            
            # log
            TUNE=$(basename "$(readlink -f "$MAS_DATA_ROOT/last_squid_tune")")	
            TUNE=${TUNE%.sqtune}
            LASTRUNFILE=$(find "$MAS_DATA" -maxdepth 1 -name "*.run" -printf '%T@ %f\n' | sort -n | tail -1 | cut -d' ' -f2)
            DATEDIR=$(basename "$(readlink -f "$MAS_DATA/$dirname")")
            x=${TUNE}"\t${RCINFO}\t${rc}\t${columns[$col]}\t${DATEDIR}\t${LASTRUNFILE%.run}"
            echo -e ${x} >> ${LOGFILE}
        done
    done
done
