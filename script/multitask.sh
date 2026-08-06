# dir=$(pwd)
# cd ../noise_taking/two_level
# ./noise_two_level_superfast.sh -t 1785439269 -c superfast_list.txt -R 0 --overwrite
# sleep 1
# cd "$dir"

# ./run_mce_raw_acq_two_level.sh -n 50 -R 1 -c 0 -C 10,11,12,13,14 -t 1785439269
# sleep 1

# ./run_mce_raw_acq_two_level.sh -f preamp -n 20 -R 1 -c 0 -C 10,11,12,13,14 -t 1785439269
# sleep 1

# ./run_mce_raw_acq_two_level.sh -f sa -n 20 -R 1 -c 0 -C 10,11,12,13,14 -t 1785439269
# sleep 1

./run_mce_raw_acq_two_level.sh -f sq1 -n 20 -R 1 -c 0 -C 10,11,12,13,14 -r 0 -t 1785439269
sleep 1

./run_mce_raw_acq_two_level.sh -f sq1 -n 20 -R 1 -c 0 -C 10,11,12,13,14 -r 1 -t 1785439269
sleep 1

./run_mce_raw_acq_two_level.sh -f sq1 -n 20 -R 1 -c 0 -C 10,11,12,13,14 -r 3 -t 1785439269
sleep 1

./run_mce_raw_acq_two_level.sh -f sq1 -n 20 -R 1 -c 0 -C 10,11,12,13,14 -r 4 -t 1785439269
sleep 1

./run_mce_raw_acq_two_level.sh -f sq1 -n 20 -R 1 -c 0 -C 10,11,12,13,14 -r 5 -t 1785439269
sleep 1

./run_mce_raw_acq_two_level.sh -f sq1 -n 20 -R 1 -c 0 -C 10,11,12,13,14 -r 6 -t 1785439269
sleep 1

./run_mce_raw_acq_two_level.sh -f sq1 -n 20 -R 1 -c 0 -C 10,11,12,13,14 -r 7 -t 1785439269
sleep 1

./run_mce_raw_acq_two_level.sh -f sq1 -n 20 -R 1 -c 0 -C 10,11,12,13,14 -r 8 -t 1785439269
sleep 1

# ./run_mce_raw_acq_two_level.sh -f sq1 -n 1 -c 0 -C 10,11,12,13,14 -r 2
# sleep 1
