#!/bin/bash

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR" || exit 1

PASS=0
FAIL=0
TEST_NUMBER=0
LOOP_FAT32=""
LOOP_EXT4=""

cleanup()
{
    set +e
    mountpoint -q myfat32fs && sudo umount myfat32fs
    mountpoint -q myext4fs && sudo umount myext4fs
    [ -n "$LOOP_FAT32" ] && sudo losetup -d "$LOOP_FAT32" 2>/dev/null
    [ -n "$LOOP_EXT4" ] && sudo losetup -d "$LOOP_EXT4" 2>/dev/null
    rm -rf myfat32fs myext4fs
    rm -f fat32disk.img ddfat32disk.img ext4disk.img ddext4disk.img
    rm -f fiofat32out.txt fioext4out.txt
}
trap cleanup EXIT INT TERM

report_test()
{
    TEST_NUMBER=$((TEST_NUMBER + 1))
    if [ "$1" -eq 0 ]; then
        echo "Test $TEST_NUMBER - Success--------------------$2--------------------Success"
        PASS=$((PASS + 1))
    else
        echo "Test $TEST_NUMBER - Fail-----------------------$2--------------------Fail"
        FAIL=$((FAIL + 1))
    fi
    echo
}

require_command()
{
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Required command not found: $1"
        exit 1
    fi
}

latency_close_enough()
{
    awk -v student="$1" -v reference="$2" 'BEGIN {
        if (student <= 0 || reference <= 0) exit 1;
        ratio = student / reference;
        exit !(ratio >= 0.5 && ratio <= 2.0);
    }'
}

fio_median_us()
{
    local output_file="$1"
    local unit
    local value

    unit=$(awk '
        /clat percentiles/ {
            if ($0 ~ /\(nsec\)/) print "nsec";
            else if ($0 ~ /\(usec\)/) print "usec";
            else if ($0 ~ /\(msec\)/) print "msec";
            exit;
        }
    ' "$output_file")

    value=$(awk '
        /50th[[:space:]]*=/ || /50\.00th[[:space:]]*=/ || /50\.000000th[[:space:]]*=/ {
            line = $0;
            sub(/^.*50(th|\.00th|\.000000th)[[:space:]]*=[[:space:]]*\[/, "", line);
            sub(/\].*$/, "", line);
            gsub(/[[:space:]]/, "", line);
            print line;
            exit;
        }
    ' "$output_file")

    if [ -z "$unit" ] || [ -z "$value" ]; then
        return 1
    fi

    awk -v value="$value" -v unit="$unit" 'BEGIN {
        if (unit == "nsec") value /= 1000.0;
        else if (unit == "msec") value *= 1000.0;
        printf "%.2f\n", value;
    }'
}

for command in gcc make dd cmp stat losetup mkfs.fat mkfs.ext4 mount umount mountpoint fio awk; do
    require_command "$command"
done

echo "This Black-Box Testing Script requires sudo access and the dosfstools,"
echo "e2fsprogs, and fio packages, as well as approximately 8 GB of free disk space."
echo

if ! sudo -v; then
    echo "Unable to obtain sudo authorization. Testing stopped."
    exit 1
fi

make clean
if ! make; then
    echo "Compilation failed. Testing stopped."
    exit 1
fi

cleanup
trap cleanup EXIT INT TERM

if ./myio 1 fat32disk.img 100000 &&
   dd if=/dev/zero of=ddfat32disk.img bs=4096 count=100000 status=none &&
   [ "$(stat -c %s fat32disk.img)" -eq 409600000 ] &&
   cmp -s fat32disk.img ddfat32disk.img; then
    report_test 0 "fat32-image-creation"
else
    report_test 1 "fat32-image-creation"
    exit 1
fi
rm -f ddfat32disk.img

LOOP_FAT32=$(sudo losetup --find --show --nooverlap --direct-io=on fat32disk.img) || exit 1
sudo mkfs.fat -a -S 512 -s 8 -F 32 -n FAT32VOL "$LOOP_FAT32" >/dev/null || exit 1
mkdir -p myfat32fs
sudo mount -t vfat -o rw,uid="$(id -u)",gid="$(id -g)" "$LOOP_FAT32" myfat32fs || exit 1

if ./myio 1 myfat32fs/fat32.t 50000; then
    report_test 0 "fat32-mounted-file-creation"
else
    report_test 1 "fat32-mounted-file-creation"
fi

sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches'
FAT32_MYIO=$(./myio 2 myfat32fs/fat32.t 4096 1000)
echo "myio-fat32-4K: $FAT32_MYIO us"
sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches'
fio --filename=myfat32fs/fat32.t --direct=1 --rw=randread --bs=4k \
    --ioengine=sync --iodepth=1 --numjobs=1 --number_ios=1000 \
    --name=readlatency-test-fat32 --readonly --clat_percentiles=1 \
    --percentile_list=50 --output=fiofat32out.txt >/dev/null 2>&1

if FAT32_FIO=$(fio_median_us fiofat32out.txt); then
    echo "fio-fat32-4K: $FAT32_FIO us"
    if latency_close_enough "$FAT32_MYIO" "$FAT32_FIO"; then
        report_test 0 "fat32-latency"
    else
        report_test 1 "fat32-latency"
    fi
else
    echo "Unable to extract the FAT32 median latency from fio output."
    report_test 1 "fat32-latency"
fi

sudo umount myfat32fs
sudo losetup -d "$LOOP_FAT32"
LOOP_FAT32=""
rm -rf myfat32fs fat32disk.img fiofat32out.txt

if ./myio 1 ext4disk.img 1000000 &&
   dd if=/dev/zero of=ddext4disk.img bs=4096 count=1000000 status=none &&
   [ "$(stat -c %s ext4disk.img)" -eq 4096000000 ] &&
   cmp -s ext4disk.img ddext4disk.img; then
    report_test 0 "ext4-image-creation"
else
    report_test 1 "ext4-image-creation"
    exit 1
fi
rm -f ddext4disk.img

LOOP_EXT4=$(sudo losetup --find --show --nooverlap --direct-io=on ext4disk.img) || exit 1
sudo mkfs.ext4 -q -b 4096 -L EXT4VOL "$LOOP_EXT4" || exit 1
mkdir -p myext4fs
sudo mount -t ext4 "$LOOP_EXT4" myext4fs || exit 1
sudo chown "$(id -u):$(id -g)" myext4fs || exit 1

if ./myio 1 myext4fs/ext4.t 500000; then
    report_test 0 "ext4-mounted-file-creation"
else
    report_test 1 "ext4-mounted-file-creation"
fi

sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches'
EXT4_MYIO=$(./myio 2 myext4fs/ext4.t 8192 10000)
echo "myio-ext4-8K: $EXT4_MYIO us"
sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches'
fio --filename=myext4fs/ext4.t --direct=1 --rw=randread --bs=8k \
    --ioengine=sync --iodepth=1 --numjobs=1 --number_ios=10000 \
    --name=readlatency-test-ext4 --readonly --clat_percentiles=1 \
    --percentile_list=50 --output=fioext4out.txt >/dev/null 2>&1

if EXT4_FIO=$(fio_median_us fioext4out.txt); then
    echo "fio-ext4-8K: $EXT4_FIO us"
    if latency_close_enough "$EXT4_MYIO" "$EXT4_FIO"; then
        report_test 0 "ext4-latency"
    else
        report_test 1 "ext4-latency"
    fi
else
    echo "Unable to extract the ext4 median latency from fio output."
    report_test 1 "ext4-latency"
fi

echo "Black-Box Testing Script Summary: $PASS/$TEST_NUMBER passed; $FAIL failed."
[ "$FAIL" -eq 0 ]
