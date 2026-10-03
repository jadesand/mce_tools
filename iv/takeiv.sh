#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 -c|--config <file> [-t|--temp <mK>] [-d|--datamode <mode>] [-r|--run <runN>] [-s|--savefig <0|1>] [-e|--eog] [-l|--relock]"
  echo "  -c, --config <file>    config file defining setup params (required)"
  echo "                         looked up in ./config/ if not found as given"
  echo "  -t, --temp <mK>        temperature for reference in mK (overrides config)"
  echo "  -d, --datamode <mode>  data mode, usually 0, 1 or 10 (overrides config)"
  echo "  -r, --run <runN>       suffix run number, or string (overrides config)"
  echo "  -s, --savefig <0|1>    save lc plots via showiv.py (overrides config)"
  echo "  -e, --eog              show plots after running (eog)"
  echo "  -l, --relock           relock (flx_lp_init) after every bias step"
  echo "  -h, --help             show this help message"
  exit "${1:-0}"
}

config=""
temp_override=""
datamode_override=""
runN_override=""
savefig_override=""
eog_override=""
relock_override=""

PARSED=$(getopt -o c:t:d:r:s:elh --long config:,temp:,datamode:,run:,savefig:,eog,relock,help -n "$0" -- "$@") || usage 1
eval set -- "$PARSED"

while true; do
  case "$1" in
    -c|--config)
      config=$2; shift 2 ;;
    -t|--temp)
      temp_override=$2; shift 2 ;;
    -d|--datamode)
      datamode_override=$2; shift 2 ;;
    -r|--run)
      runN_override=$2; shift 2 ;;
    -s|--savefig)
      savefig_override=$2; shift 2 ;;
    -e|--eog)
      eog_override=1; shift ;;
    -l|--relock)
      relock_override=1; shift ;;
    -h|--help)
      usage 0 ;;
    --)
      shift; break ;;
    *)
      usage 1 ;;
  esac
done

if [ -z "$config" ]; then
  echo "Error: -c/--config <file> is required" >&2
  usage 1
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
if [ ! -f "$config" ] && [ -f "$script_dir/config/$config" ]; then
  config="$script_dir/config/$config"
fi
if [ ! -f "$config" ]; then
  echo "Error: config file '$config' not found" >&2
  exit 1
fi

# Defaults, in case the config file omits them
temp=245
datamode=1
runN=0
savefig=1
eog=0
relock=0
lcprefix="FPU"
datadir="\$MAS_DATA"
nrow=22
ncol=32

# shellcheck disable=SC1090
source "$config"

# CLI flags override config values
[ -n "$temp_override" ] && temp=$temp_override
[ -n "$datamode_override" ] && datamode=$datamode_override
[ -n "$runN_override" ] && runN=$runN_override
[ -n "$savefig_override" ] && savefig=$savefig_override
[ -n "$eog_override" ] && eog=$eog_override
[ -n "$relock_override" ] && relock=$relock_override

# Resolve datadir (config may reference $MAS_DATA etc. as a literal string)
datadir=$(eval echo "$datadir")

lcname="LC_${lcprefix}_FPU_${temp}mK_datamode${datamode}_run${runN}"
relock_arg=""
if [ "$relock" -eq 1 ]; then
  lcname="${lcname}_relock"
  relock_arg="--relock"
fi
echo "$lcname"
lcfullpath="$datadir/$lcname"
lcplots="$lcfullpath/"

# Take iv curve
./ivcurve.py \
  --dataname "$lcname" \
  --columns $columns \
  --bias_start "$bias_start" \
  --bias_step "$bias_step" \
  --bias_count "$bias_count" \
  --bias_pause "$bias_pause" \
  --bias_final "$bias_final" \
  --data_mode "$datamode" \
  $relock_arg \
  --zap_bias "$zap_bias" \
  --zap_time "$zap_time" \
  --settle_bias "$settle_bias" \
  --settle_time "$settle_time"

# Produce plots
if [ "$savefig" -eq 1 ]; then
  ./showiv.py "$lcfullpath" --nrow "$nrow" --ncol "$ncol" --columns $columns $relock_arg
fi

# Show plots
if [ "$eog" -eq 1 ]; then
  eog "$lcplots"*.png &
fi
