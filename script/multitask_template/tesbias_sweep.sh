dir=$(pwd)

SCRIPT_DIR=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
cd "$SCRIPT_DIR/../python"

SQWAVE_SCRIPT="$SCRIPT_DIR/run_tesbias_sqwave.sh"

# mas_param set defaults to printing the resulting config to stdout
# instead of writing it back to $MAS_DATA/experiment.cfg -- pass -f
# explicitly on every set so the change actually persists to the file
# auto_setup reads from.
EXP_CFG="$MAS_DATA/experiment.cfg"
mas_param() {
    if [ "$1" == "set" ]; then
        command mas_param "$@" -f "$EXP_CFG"
    else
        command mas_param "$@"
    fi
}

# row_order/num_rows/sample_dly etc. are left as whatever the most
# recent tune already wrote into $MAS_DATA/experiment.cfg -- no
# default_row_select/row_order override here, unlike the old AC2
# sweep version of this script. run_tesbias_sqwave.sh (with no
# --tune-ctime) uses that same live $MAS_DATA/experiment.cfg as-is.

# TES bias sweep: for each N in 1..10, run a square-wave calibration
# (0/N toggle) via run_tesbias_sqwave.sh.
N_CYCLES=3
N_TESTS=10
PERIOD=50

RUN_TAG=$(date +%s)

# for rlen in {90..40..2} # 30, 40, ..., 100?
for rlen in 90 60 50
do
    mas_param set row_len $rlen
    mas_param set ac2_row_len $rlen
    mas_param set sample_dly $(( rlen - 10 ))

    sleep 1
    auto_setup
    sleep 1

    for n in $(seq 1 $N_TESTS); do
        "$SQWAVE_SCRIPT" \
            --rc="s" \
            --row-len $rlen \
            --step-size $n \
            --n-cycles $N_CYCLES \
            --period $PERIOD \
            --run "${RUN_TAG}_rlen${rlen}_n${n}" \
            --overwrite
    done
done

sleep 1
mce_zero_bias > /dev/null
sleep 1

cd "$dir"
