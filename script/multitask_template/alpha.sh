EXP_CFG="$MAS_DATA/experiment.cfg"
mas_param() {
    if [ "$1" == "set" ]; then
        command mas_param "$@" -f "$EXP_CFG"
    else
        command mas_param "$@"
    fi
}

dir=$(pwd)
cd /home/mce/rshi/mce_tools/iv

while true; do

    ./takeiv.sh --config 20261104_nist_alpha.cfg --run "$(date +%s)"

    sleep 2

done