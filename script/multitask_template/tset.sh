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

### settling time

# default sq1 branch (whatever that is, remember to run sweep.py to confirm)
for bias in $(seq 5000 1000 18000); do
    mce_zero_bias > /dev/null
    sleep 1
    mas_param set row_len 119
    mas_param set sample_dly 109
    mas_param set default_servo_i $(printf '30 %.0s' {1..16})
    mas_param set default_sq1_bias $bias $bias $bias $bias $bias $bias $bias $bias $bias $bias $bias $bias 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    sleep 1
    echo "default_servo_i=$(mas_param get row_len)"
    echo "default_sq1_bias=$(mas_param get sample_dly)"
    echo "default_servo_i=$(mas_param get default_servo_i)"
    echo "default_sq1_bias=$(mas_param get default_sq1_bias)"
    sleep 1
    auto_setup
    sleep 1
    ./run_mce_raw_acq.sh -n 4
done


# flip the sign of default_servo_i to switch to the other sq1 branch
for bias in $(seq 5000 1000 18000); do
    mce_zero_bias > /dev/null
    sleep 1
    mas_param set row_len 119
    mas_param set sample_dly 109
    mas_param set default_servo_i $(printf -- '-30 %.0s' {1..16})
    mas_param set default_sq1_bias $bias $bias $bias $bias $bias $bias $bias $bias $bias $bias $bias $bias 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    sleep 1
    echo "default_servo_i=$(mas_param get row_len)"
    echo "default_sq1_bias=$(mas_param get sample_dly)"
    echo "default_servo_i=$(mas_param get default_servo_i)"
    echo "default_sq1_bias=$(mas_param get default_sq1_bias)"
    sleep 1
    auto_setup
    sleep 1
    ./run_mce_raw_acq.sh -n 4
done



sleep 1
mce_zero_bias > /dev/null
sleep 1