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

nchips=5
nrows=50

# repeat $1 nchips times, space separated
repeat_nchips() {
    local i
    for ((i = 0; i < nchips; i++)); do printf '%s ' "$1"; done
}

repeat_nrows() {
    local i
    for ((i = 0; i < nrows; i++)); do printf '%s ' "$1"; done
}



default_ac_on_bias=6000

### cs on rs on
echo "cs on rs on"
mas_param set sq1_servo_bias_ramp 1
mas_param set default_ac2_on_bias $(repeat_nchips ${default_ac_on_bias})
mas_param set default_ac2_off_bias $(repeat_nchips 0)

mas_param set default_row_select $(repeat_nrows ${default_ac_on_bias})
mas_param set default_row_deselect $(repeat_nrows 0)

echo "default_ac2_on_bias=$(mas_param get default_ac2_on_bias)"
echo "default_ac2_off_bias=$(mas_param get default_ac2_off_bias)"
echo "default_row_select=$(mas_param get default_row_select)"
echo "default_row_deselect=$(mas_param get default_row_deselect)"

sleep 1
auto_setup --last-stage=sq1_servo_sa
sleep 1

### cs on rs off
echo "cs on rs off"
mas_param set sq1_servo_bias_ramp 1
mas_param set default_ac2_on_bias $(repeat_nchips ${default_ac_on_bias})
mas_param set default_ac2_off_bias $(repeat_nchips 0)

mas_param set default_row_select $(repeat_nrows 0)
mas_param set default_row_deselect $(repeat_nrows 0)

echo "default_ac2_on_bias=$(mas_param get default_ac2_on_bias)"
echo "default_ac2_off_bias=$(mas_param get default_ac2_off_bias)"
echo "default_row_select=$(mas_param get default_row_select)"
echo "default_row_deselect=$(mas_param get default_row_deselect)"

sleep 1
auto_setup --last-stage=sq1_servo_sa
sleep 1


### cs off rs on
echo "cs off rs on"
mas_param set sq1_servo_bias_ramp 1
mas_param set default_ac2_on_bias $(repeat_nchips 0)
mas_param set default_ac2_off_bias $(repeat_nchips 0)

mas_param set default_row_select $(repeat_nrows 0)
mas_param set default_row_deselect $(repeat_nrows ${default_ac_on_bias})

echo "default_ac2_on_bias=$(mas_param get default_ac2_on_bias)"
echo "default_ac2_off_bias=$(mas_param get default_ac2_off_bias)"
echo "default_row_select=$(mas_param get default_row_select)"
echo "default_row_deselect=$(mas_param get default_row_deselect)"

sleep 1
auto_setup --last-stage=sq1_servo_sa
sleep 1


### cs off rs off
echo "cs off rs off"
mas_param set sq1_servo_bias_ramp 1
mas_param set default_ac2_on_bias $(repeat_nchips 0)
mas_param set default_ac2_off_bias $(repeat_nchips 0)

mas_param set default_row_select $(repeat_nrows 0)
mas_param set default_row_deselect $(repeat_nrows 0)

echo "default_ac2_on_bias=$(mas_param get default_ac2_on_bias)"
echo "default_ac2_off_bias=$(mas_param get default_ac2_off_bias)"
echo "default_row_select=$(mas_param get default_row_select)"
echo "default_row_deselect=$(mas_param get default_row_deselect)"

sleep 1
auto_setup --last-stage=sq1_servo_sa
sleep 1


sleep 1
mce_zero_bias > /dev/null
sleep 1

rm $MAS_DATA/experiment.cfg