
# Defaults
temp=245       # temperature for reference in mK
datamode=1     # usually only uses 0, 1 and 10
runN=0         # suffix run number, or string
show=0
relock=0

usage() {
  echo "Usage: $0 [-t|--temp <mK>] [-d|--datamode <mode>] [-r|--run <runN>] [-s|--show] [-l|--relock]"
  echo "  -t, --temp <mK>        temperature for reference in mK (default: $temp)"
  echo "  -d, --datamode <mode>  data mode, usually 0, 1 or 10 (default: $datamode)"
  echo "  -r, --run <runN>       suffix run number, or string (default: $runN)"
  echo "  -s, --show             show plots after running (eog) (default: off)"
  echo "  -l, --relock           relock (flx_lp_init) after every bias step (default: off)"
  echo "  -h, --help             show this help message"
  exit "${1:-0}"
}

PARSED=$(getopt -o t:d:r:slh --long temp:,datamode:,run:,show,relock,help -n "$0" -- "$@") || usage 1
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
    -l|--relock)
      relock=1; shift ;;
    -h|--help)
      usage 0 ;;
    --)
      shift; break ;;
    *)
      usage 1 ;;
  esac
done

# Change lcname every time you run something
lcname="LC_mirror_FPU_"$temp"mK_datamode"$datamode"_run"$runN
relock_arg=""
if [ $relock -eq 1 ]; then
  lcname=$lcname"_relock"
  relock_arg="--relock"
fi
echo $lcname
lcfullpath="$MAS_DATA/$lcname"
lcplots=$lcfullpath"/"

# Take iv curve
# (no comment lines inside the backslash-continued command -- they end it)
#  --columns 17 18 19 20 21 22 23 25 26 27 \
./ivcurve.py \
  --dataname $lcname \
  --columns 17 18 19 21 22 23 25 27 \
  --bias_start 1500 \
  --bias_step -1 \
  --bias_count 1500 \
  --bias_pause 0.05 \
  --bias_final 0 \
  --data_mode $datamode \
  $relock_arg \
  --zap_bias 32767 \
  --zap_time 2 \
  --settle_bias 1500 \
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
