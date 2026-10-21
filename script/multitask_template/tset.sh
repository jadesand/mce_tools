# mas_param set defaults to printing te resulting config to stdout
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

sq1bias_list=$(seq 5000 1000 18000)
row_len=119
sample_dly=109
default_servo_i=30
ncols=16
nall_cols=32   # length of default_sq1_bias
columns=(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)   # global columns 0..31
columns_csv=$(IFS=,; echo "${columns[*]}")
ndpkg=4

# repeat $1 ncols times, space separated
repeat_ncols() {
    local i
    for ((i = 0; i < ncols; i++)); do printf '%s ' "$1"; done
}

# default_sq1_bias list: $1 at the global columns listed in $columns, 0 elsewhere
sq1_bias_at_columns() {
    local i c v
    for ((i = 0; i < nall_cols; i++)); do
        v=0
        for c in "${columns[@]}"; do
            [ "$c" -eq "$i" ] && v=$1
        done
        printf '%s ' "$v"
    done
}

### settling time

# default sq1 branch (whatever that is, remember to run sweep.py to confirm)
for bias in $sq1bias_list; do
    mce_zero_bias > /dev/null
    sleep 1
    mas_param set row_len ${row_len}
    mas_param set sample_dly ${sample_dly}
    mas_param set default_servo_i $(repeat_ncols ${default_servo_i})
    mas_param set default_sq1_bias $(sq1_bias_at_columns $bias)
    sleep 1
    echo "default_servo_i=$(mas_param get row_len)"
    echo "default_sq1_bias=$(mas_param get sample_dly)"
    echo "default_servo_i=$(mas_param get default_servo_i)"
    echo "default_sq1_bias=$(mas_param get default_sq1_bias)"
    sleep 1
    auto_setup
    sleep 1
    ./run_mce_raw_acq.sh -n ${ndpkg} -c ${columns_csv}
done


# flip the sign of default_servo_i to switch to the other sq1 branch
for bias in $sq1bias_list; do
    mce_zero_bias > /dev/null
    sleep 1
    mas_param set row_len ${row_len}
    mas_param set sample_dly ${sample_dly}
    mas_param set default_servo_i $(repeat_ncols -${default_servo_i})
    mas_param set default_sq1_bias $(sq1_bias_at_columns $bias)
    sleep 1
    echo "default_servo_i=$(mas_param get row_len)"
    echo "default_sq1_bias=$(mas_param get sample_dly)"
    echo "default_servo_i=$(mas_param get default_servo_i)"
    echo "default_sq1_bias=$(mas_param get default_sq1_bias)"
    sleep 1
    auto_setup
    sleep 1
    ./run_mce_raw_acq.sh -n ${ndpkg} -c ${columns_csv}
done



sleep 1
mce_zero_bias > /dev/null
sleep 1