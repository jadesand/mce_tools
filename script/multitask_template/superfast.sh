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

dir=$(pwd)
cd /home/mce/rshi/mce_tools/noise_taking/20261010_NIST_12col50row

# nominal default_servo_i
# rm $MAS_DATA/experiment.cfg
# auto_setup
sleep 1
echo "default_servo_i=$(mas_param get default_servo_i)"
sleep 1

./superfast.sh -R 1 --channel-list superfast_channel_list_full.txt

# default_servo_i = -30
sleep 1
mas_param set default_servo_i $(printf -- '-30 %.0s' {1..16})
sleep 1
echo "default_servo_i=$(mas_param get default_servo_i)"
sleep 1
auto_setup
sleep 1

./superfast.sh -R 2 --channel-list superfast_channel_list_full.txt


sleep 1
mce_zero_bias > /dev/null
sleep 1

cd "$dir"