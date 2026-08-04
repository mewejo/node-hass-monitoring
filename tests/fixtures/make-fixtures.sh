#!/usr/bin/env bash
# Builds the fake /sys trees the sensor unit tests run against.
#
# Generated rather than committed because the trees rely on symlinks (the
# hwmon -> device links are what make chip slugs stable) and on empty-ish files,
# both of which are awkward to keep faithful in git across checkouts.
#
# The "typical" tree reproduces real readings captured from an AMD desktop
# during design, including every awkward case found there: two chips sharing a
# name, five sensors sharing a label, out-of-range junk values, and a wireless
# mouse battery masquerading as a temperature sensor.
set -euo pipefail

FIXTURE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

make_hwmon() {
    local root=$1 index=$2 name=$3 devpath=$4
    local dir="${root}/class/hwmon/hwmon${index}"
    mkdir -p "$dir"
    printf '%s\n' "$name" >"${dir}/name"

    if [[ -n $devpath ]]; then
        mkdir -p "${root}/devices/${devpath}"
        ln -sfn "../../../devices/${devpath}" "${dir}/device"
    fi
}

add_temp() {
    local root=$1 index=$2 num=$3 label=$4 value=$5
    local dir="${root}/class/hwmon/hwmon${index}"
    printf '%s\n' "$value" >"${dir}/temp${num}_input"
    [[ -n $label ]] && printf '%s\n' "$label" >"${dir}/temp${num}_label"
    return 0
}

build_typical() {
    local root="${FIXTURE_DIR}/sysfs-typical"
    rm -rf "$root"
    mkdir -p "$root/class/hwmon"

    # Two NVMe drives. Same chip name, same labels: only the device link tells
    # them apart, which is why chip slugs derive from it.
    make_hwmon "$root" 0 nvme "pci0000:00/0000:00:01.1/nvme/nvme0"
    add_temp "$root" 0 1 "Composite" 53850
    add_temp "$root" 0 2 "Sensor 1" 53850
    add_temp "$root" 0 3 "Sensor 2" 56850

    make_hwmon "$root" 1 nvme "pci0000:00/0000:00:01.2/nvme/nvme1"
    add_temp "$root" 1 1 "Composite" 32850
    add_temp "$root" 1 2 "Sensor 1" 32850
    add_temp "$root" 1 3 "Sensor 2" 51850

    # CPU. Note temp2 is absent: numbering is sparse, so the walk must not
    # assume a contiguous 1..N range.
    make_hwmon "$root" 2 k10temp "pci0000:00/0000:00:18.3"
    add_temp "$root" 2 1 "Tctl" 70125
    add_temp "$root" 2 3 "Tccd1" 64750
    add_temp "$root" 2 4 "Tccd2" 69250

    # Super-I/O chip: the messy one. Five sensors share the label
    # "Virtual_TEMP", and two report impossible values from unconnected pins.
    make_hwmon "$root" 3 nct6797 "platform/nct6775.2592"
    add_temp "$root" 3 1 "SYSTIN" 46000
    add_temp "$root" 3 2 "CPUTIN" 54000
    add_temp "$root" 3 3 "AUXTIN0" 54500
    add_temp "$root" 3 4 "AUXTIN1" -128000
    add_temp "$root" 3 5 "AUXTIN2" 58000
    add_temp "$root" 3 6 "AUXTIN3" -1000
    add_temp "$root" 3 7 "Virtual_TEMP" 70000
    add_temp "$root" 3 8 "Virtual_TEMP" 70000
    add_temp "$root" 3 9 "Virtual_TEMP" 46000
    add_temp "$root" 3 10 "Virtual_TEMP" 70000
    add_temp "$root" 3 11 "Virtual_TEMP" 46000

    # GPU, including a sensor reading exactly zero because the card is idle.
    make_hwmon "$root" 4 amdgpu "pci0000:00/0000:0c:00.0"
    add_temp "$root" 4 1 "edge" 55000
    add_temp "$root" 4 2 "junction" 55000
    add_temp "$root" 4 3 "mem" 0

    # A wireless mouse. Not a node temperature by any reading of the word.
    make_hwmon "$root" 5 hidpp_battery_0 "devices/hid0003"
    add_temp "$root" 5 1 "" 0

    # An unlabelled chip with no device link, exercising both fallbacks.
    make_hwmon "$root" 6 acpitz ""
    add_temp "$root" 6 1 "" 42000
}

# Machines with no hwmon temperatures at all (common on ARM boards and some
# VMs) must still report something, via the thermal-zone fallback.
build_thermal_only() {
    local root="${FIXTURE_DIR}/sysfs-thermal-only"
    rm -rf "$root"
    mkdir -p "$root/class/thermal/thermal_zone0" "$root/class/thermal/thermal_zone1"

    printf 'x86_pkg_temp\n' >"$root/class/thermal/thermal_zone0/type"
    printf '48000\n' >"$root/class/thermal/thermal_zone0/temp"

    printf 'acpitz\n' >"$root/class/thermal/thermal_zone1/type"
    printf '27800\n' >"$root/class/thermal/thermal_zone1/temp"

    # hwmon exists but exposes no temperature inputs, so the fallback has to
    # trigger on "no readings" rather than "no hwmon directory".
    mkdir -p "$root/class/hwmon/hwmon0"
    printf 'hidpp_battery_0\n' >"$root/class/hwmon/hwmon0/name"
}

# A node with no thermal sensors at all. Must degrade quietly, not crash.
build_empty() {
    local root="${FIXTURE_DIR}/sysfs-empty"
    rm -rf "$root"
    mkdir -p "$root/class"
}

# The typical tree with the GPU removed, for testing stale-entity cleanup.
build_gpu_removed() {
    local root="${FIXTURE_DIR}/sysfs-gpu-removed"
    rm -rf "$root"
    cp -a "${FIXTURE_DIR}/sysfs-typical" "$root"
    rm -rf "${root}/class/hwmon/hwmon4"
}

build_typical
build_thermal_only
build_empty
build_gpu_removed

echo "fixtures built in ${FIXTURE_DIR}"
