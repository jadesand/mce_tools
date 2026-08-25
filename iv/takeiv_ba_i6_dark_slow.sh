
# Defaults
temp=300       # temperature for reference in mK
datamode=1     # usually only uses 0, 1 and 10
runN=0         # suffix run number, or string
show=0

usage() {
  echo "Usage: $0 [-t|--temp <mK>] [-d|--datamode <mode>] [-r|--run <runN>] [-s|--show]"
  echo "  -t, --temp <mK>        temperature for reference in mK (default: $temp)"
  echo "  -d, --datamode <mode>  data mode, usually 0, 1 or 10 (default: $datamode)"
  echo "  -r, --run <runN>       suffix run number, or string (default: $runN)"
  echo "  -s, --show             show plots after running (eog) (default: off)"
  echo "  -h, --help             show this help message"
  exit "${1:-0}"
}

PARSED=$(getopt -o t:d:r:sh --long temp:,datamode:,run:,show,help -n "$0" -- "$@") || usage 1
eval set -- "$PARSED"

while true; do
  case "$1" in
    -t|--temp)
      temp=$2; shift 2 ;;
    -d|--datamode)
      datamode=$2; shift 2 ;;
    -r|--run)
      runN=$2; shift 2 ;;
    -s|--show)
      show=1; shift ;;
    -h|--help)
      usage 0 ;;
    --)
      shift; break ;;
    *)
      usage 1 ;;
  esac
done

# Change lcname every time you run something
lcname="LC_dark_FPU_"$temp"mK_datamode"$datamode"_run"$runN
echo $lcname
lcfullpath="/data/cryo/current_data/"$lcname
lcplots=$lcfullpath"/"

# Take iv curve
./ivcurve.py \
  --dataname $lcname \
  --columns 1 2 3 4 6 7 8 9 10 11 12 13 14 15\
  --bias_start 15000 \
  --bias_step -40 \
  --bias_count 300 \
  --bias_pause 10 \
  --bias_final 0 \
  --data_mode $datamode \
  --zap_bias 15000 \
  --zap_time 10 \
  --settle_bias 15000 \
  --settle_time 10 \
#  --cooling_time 3600 \
#  --temp $temp
#  --runN $runN

# Produce plots
./showiv.py $lcfullpath

# Show plots
if [ $show -eq 1 ]; then
  eog $lcplots*.png &
fi

# Titanium
#  --bias_start 10000 \
#  --bias_step -10 \
#  --bias_count 1001 \
#  --zap_bias 10000 \
#  --zap_time 1.0 \

# Aluminum
#  --bias_start 65000 \
#  --bias_step -100 \
#  --bias_count 651 \
