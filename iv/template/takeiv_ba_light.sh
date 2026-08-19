
temp=${1:-250}
datamode=${2:-1}
runN=${3:-1}
#lcname=$1

# Change lcname every time you run something
lcname="LC_light_FPU_"$temp"mK_datamode"$datamode"_run"$runN
lcfullpath="/data/cryo/current_data/"$lcname
lcplots=$lcfullpath"/"

# Take iv curve
./ivcurve.py \
  --dataname $lcname \
  --columns 5 8 12\
  --bias_start 10000 \
  --bias_step -10 \
  --bias_count 1001 \
  --bias_pause 0.1 \
  --bias_final 0 \
  --data_mode $datamode \
  --zap_bias 65535 \
  --zap_time 0.1 \
  --settle_time 1.0 \
  --settle_bias 10000 \
#  --cooling_time 3600 \
#  --temp $temp
#  --runN $runN

# Produce plots
#./showiv_bydet.py $lcfullpath
#python showiv.py $lcfullpath

# Show plots
#eog $lcplots*.png &


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
