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
cd /home/mce/rshi/mce_tools/script

nsamples=20

# (row, addr) pairs shared by every sq1 sweep below
# SQ1_ROWS_ADDRS=(
#     "0 10"
#     "5 10"
#     "11 11"
#     "16 11"
#     "22 12"
#     "26 12"
#     "33 13"
#     "38 13"
#     "44 14"
#     "49 14"
# )
SQ1_ROWS_ADDRS=(
    "0 10"
    "11 11"
)

run_sq1_sweep() {
    for ra in "${SQ1_ROWS_ADDRS[@]}"; do
        read -r r a <<< "$ra"
        ./run_mce_raw_acq.sh -f 'sq1' -n "${nsamples}" -r "$r" -a "$a"
        sleep 1
    done
}

reset_setup() {
    rm "$MAS_DATA/experiment.cfg"
    auto_setup
    sleep 1
}

### Preamp
reset_setup
./run_mce_raw_acq.sh -f 'preamp' -n ${nsamples}
sleep 1

### SA + SQ1
## nominal default_servo_i and default_sa_bias
reset_setup
echo "default_servo_i=$(mas_param get default_servo_i)"
sleep 1

./run_mce_raw_acq.sh -f 'sa' -n ${nsamples}
sleep 1

run_sq1_sweep

## flipped default_servo_i
mas_param set default_servo_i $(printf -- '-30 %.0s' {1..16})
sleep 1
echo "default_servo_i=$(mas_param get default_servo_i)"
sleep 1
auto_setup
sleep 1

run_sq1_sweep

## overbias SA, default_servo_i = -30
mas_param set default_sa_bias 32300 34200 32300 33300 33300 34200 32300 34200 22800 22800 23700 23700 23700 22800 23700 22800 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
sleep 1
mas_param set default_servo_i $(printf -- '30 %.0s' {1..16})
sleep 1
echo "default_sa_bias=$(mas_param get default_sa_bias)"
sleep 1
echo "default_servo_i=$(mas_param get default_servo_i)"
sleep 1
auto_setup
sleep 1

./run_mce_raw_acq.sh -f 'sa' -n ${nsamples}
sleep 1

run_sq1_sweep

## flipped default_servo_i
mas_param set default_sa_bias 32300 34200 32300 33300 33300 34200 32300 34200 22800 22800 23700 23700 23700 22800 23700 22800 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
sleep 1
mas_param set default_servo_i $(printf -- '-30 %.0s' {1..16})
sleep 1
echo "default_sa_bias=$(mas_param get default_sa_bias)"
sleep 1
echo "default_servo_i=$(mas_param get default_servo_i)"
sleep 1
auto_setup
sleep 1

run_sq1_sweep

sleep 1
mce_zero_bias > /dev/null
sleep 1

cd "$dir"
