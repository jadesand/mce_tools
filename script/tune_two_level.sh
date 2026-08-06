#!/bin/bash
PARENT_NAME="two_level_$(date +%s)"
rc=1
chip_list=(10 11 12 13 14)

opts=$(getopt -o r:c: --long rc:,chip_list: -n "$(basename "$0")" -- "$@")
if [[ $? -ne 0 ]]; then
    exit 1
fi
eval set -- "$opts"

while true; do
    case "$1" in
        -r|--rc)
            rc="$2"
            shift 2
            ;;
        -c|--chip_list)
            read -r -a chip_list <<< "$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Internal error!" >&2
            exit 1
            ;;
    esac
done

# Resolve the symlink to get the real path
MAS_DATA_REAL="/data/cryo/$(date +%Y%m%d)"

MAS_CONFIG="${MAS_CONFIG:-/usr/mce/config}"
ARRAY_ID=$(cat "$MAS_DATA_ROOT/array_id")
DEAD_DIR="$MAS_CONFIG/dead_lists/$ARRAY_ID"

mkdir -p "$MAS_DATA_REAL/$PARENT_NAME"
mkdir -p "$MAS_DATA_REAL/analysis/$PARENT_NAME"

# rowsel_servo_gain_per_chip=(-0.01 0.01 0.01 0.01 0.01 0.01 0.01 -0.01)
# sq1_servo_gain_per_chip=(-0.01 0.01 0.01 0.01 0.01 0.01 0.01 -0.01)

{
for i in "${!chip_list[@]}"; do
    CS=${chip_list[$i]}
    echo "CS=$CS"
    # rowsel_servo_gain=${rowsel_servo_gain_per_chip[$i]}
    # sq1_servo_gain=${sq1_servo_gain_per_chip[$i]}

    mce_zero_bias > /dev/null 2>&1
    mas_param set row_order 0 1 2 3 4 5 6 7 8 9 ${CS}

    # mas_param set rowsel_servo_gain $(yes -- "$rowsel_servo_gain" | head -32 | tr '\n' ' ')
    # mas_param set sq1_servo_gain $(yes -- "$sq1_servo_gain" | head -32 | tr '\n' ' ')

    # Point dead_squid1.cfg at the per-CS mask before auto_setup reads it
    ln -sf "$DEAD_DIR/dead_squid1_cs$((CS-10)).cfg" "$DEAD_DIR/dead_squid1.cfg"

    auto_setup --rc=$rc
    
    # Find the most recently created directory
    LATEST=$(find "$MAS_DATA_REAL" -maxdepth 1 -type d \
             -not -path "$MAS_DATA_REAL" \
             -not -path "$MAS_DATA_REAL/$PARENT_NAME" \
             -printf '%T+ %p\n' | sort -r | head -1 | cut -d' ' -f2-)
    
    if [[ -n "$LATEST" ]]; then
        DIRNAME=$(basename "$LATEST")
        mv "$MAS_DATA_REAL/$DIRNAME" "$MAS_DATA_REAL/$PARENT_NAME/CS$((CS-10))"
        mv "$MAS_DATA_REAL/analysis/$DIRNAME" "$MAS_DATA_REAL/analysis/$PARENT_NAME/CS$((CS-10))"
    fi
done
} 2>&1 | tee "$MAS_DATA_REAL/$PARENT_NAME/log"