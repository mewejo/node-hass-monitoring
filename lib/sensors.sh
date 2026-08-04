#!/usr/bin/env bash
# Temperature collection from sysfs.
#
# Emits one record per sensor: key<TAB>display name<TAB>celsius
#
# Everything downstream (discovery, state publishing) is generic over that
# format, so adding CPU load, memory or disk sensors later means adding another
# collector here rather than touching the MQTT or Home Assistant code.
#
# Sourceable with no side effects: this file only defines functions. Reads from
# ${SYSFS_ROOT:-/sys} so tests can point it at a fixture tree.

# Readings outside this range are not real temperatures. Super-I/O chips report
# values like -128 C or -1 C from pins with nothing connected to them, and idle
# GPU memory sensors report exactly 0. Publishing those produces alarming and
# meaningless graphs in Home Assistant.
#
# The lower bound is deliberately below freezing rather than at 0: nodes in
# garages, lofts and outbuildings genuinely read below zero in winter.
: "${SENSORS_MIN_CELSIUS:=-50}"
: "${SENSORS_MAX_CELSIUS:=150}"

# Chips to skip regardless of their readings. Peripheral batteries appear in
# hwmon exactly like temperature sensors do -- a wireless mouse shows up as
# hidpp_battery_0 -- and are not node temperatures by any reading of the word.
# Overridable in config.env for pruning noisy chips.
: "${IGNORE_PATTERN:=hidpp_battery|_battery$|^BAT[0-9]}"

# Lowercase, collapse anything outside [a-z0-9] to underscores, trim repeats.
# Keys become MQTT topic segments and Home Assistant entity ids, so stray
# characters cause trouble a long way from here.
sensors_slugify() {
    local s=$1
    s=${s,,}
    s=${s//[^a-z0-9]/_}
    while [[ $s == *__* ]]; do s=${s//__/_}; done
    s=${s#_}
    s=${s%_}
    printf '%s' "$s"
}

# Millidegrees to Celsius with one decimal place.
#
# Integer arithmetic rather than bc or awk: bc is genuinely absent on minimal
# installs, and this needs to work on a bare Proxmox node.
sensors_millidegrees_to_celsius() {
    local milli=$1
    local sign="" whole frac rounded

    if ((milli < 0)); then
        sign="-"
        milli=$((-milli))
    fi

    # Round to the nearest 100 millidegrees (0.1 C) rather than truncating, so
    # 53850 reads as 53.9 rather than 53.8.
    rounded=$(((milli + 50) / 100))
    whole=$((rounded / 10))
    frac=$((rounded % 10))

    printf '%s%d.%d' "$sign" "$whole" "$frac"
}

sensors_is_plausible() {
    local milli=$1

    # Exactly zero is almost always an unpopulated sensor rather than a genuine
    # 0.0 C reading. Treating it as junk loses nothing real.
    ((milli == 0)) && return 1

    ((milli >= SENSORS_MIN_CELSIUS * 1000)) || return 1
    ((milli <= SENSORS_MAX_CELSIUS * 1000)) || return 1
    return 0
}

# A stable identifier for an hwmon chip.
#
# The hwmonN index cannot be used: it is enumeration order and can shuffle
# across reboots or kernel updates, which would rename every entity in Home
# Assistant and orphan all their history. The device symlink points at the
# underlying hardware (a PCI address, or an nvme device), which is stable and
# also distinguishes two chips that share a name -- two NVMe drives both report
# chip name "nvme" with a sensor labelled "Composite".
sensors_chip_slug() {
    local hwmon_dir=$1
    local target

    if [[ -e "${hwmon_dir}/device" ]]; then
        target=$(readlink -f "${hwmon_dir}/device" 2>/dev/null)
        if [[ -n $target ]]; then
            printf '%s' "$(sensors_slugify "$(basename "$target")")"
            return 0
        fi
    fi

    # No device link (some platform and ACPI chips). Fall back to the hwmon
    # index, accepting that this one is not reboot-stable.
    printf '%s' "$(sensors_slugify "$(basename "$hwmon_dir")")"
}

# Collect from /sys/class/hwmon, the primary source.
sensors_collect_hwmon() {
    local root="${SYSFS_ROOT:-/sys}"
    local hwmon_dir input_file chip chip_slug label num key value name

    for hwmon_dir in "${root}"/class/hwmon/hwmon*; do
        [[ -d $hwmon_dir ]] || continue

        chip=""
        [[ -r "${hwmon_dir}/name" ]] && read -r chip <"${hwmon_dir}/name"
        [[ -n $chip ]] || chip=$(basename "$hwmon_dir")

        [[ $chip =~ $IGNORE_PATTERN ]] && continue

        chip_slug=$(sensors_chip_slug "$hwmon_dir")

        # Glob rather than counting from 1: numbering is sparse. k10temp
        # exposes temp1, temp3 and temp4 with no temp2, so a contiguous loop
        # would stop early and silently drop the per-CCD sensors.
        for input_file in "${hwmon_dir}"/temp*_input; do
            [[ -r $input_file ]] || continue

            value=""
            read -r value <"$input_file" 2>/dev/null
            [[ $value =~ ^-?[0-9]+$ ]] || continue
            sensors_is_plausible "$value" || continue

            num=$(basename "$input_file")
            num=${num#temp}
            num=${num%_input}

            label=""
            [[ -r "${hwmon_dir}/temp${num}_label" ]] && read -r label <"${hwmon_dir}/temp${num}_label"

            key=$(sensors_slugify "${chip}_${chip_slug}_temp${num}")

            if [[ -n $label ]]; then
                name="${chip} ${label}"
            else
                name="${chip} temp${num}"
            fi

            printf '%s\t%s\t%s\t%s\n' "$key" "$name" "$(sensors_millidegrees_to_celsius "$value")" "$label"
        done
    done
}

# Fallback for machines with no hwmon temperatures, which is common on ARM
# boards and inside some VMs.
sensors_collect_thermal_zones() {
    local root="${SYSFS_ROOT:-/sys}"
    local zone type value key zone_name

    for zone in "${root}"/class/thermal/thermal_zone*; do
        [[ -d $zone ]] || continue
        [[ -r "${zone}/temp" ]] || continue

        type=""
        [[ -r "${zone}/type" ]] && read -r type <"${zone}/type"
        zone_name=$(basename "$zone")
        [[ -n $type ]] || type=$zone_name

        [[ $type =~ $IGNORE_PATTERN ]] && continue

        value=""
        read -r value <"${zone}/temp" 2>/dev/null
        [[ $value =~ ^-?[0-9]+$ ]] || continue
        sensors_is_plausible "$value" || continue

        key=$(sensors_slugify "${type}_${zone_name}")
        printf '%s\t%s\t%s\t%s\n' "$key" "$type" "$(sensors_millidegrees_to_celsius "$value")" "$type"
    done
}

# Disambiguate display names.
#
# A chip can expose several sensors sharing one label -- nct6797 reports five
# separate sensors all labelled "Virtual_TEMP" -- and five identically named
# entities in the Home Assistant UI are unusable. Only the ambiguous ones get a
# suffix, so the common case stays clean ("k10temp Tctl", not
# "k10temp Tctl (temp1)").
sensors_disambiguate_names() {
    local -A name_counts=()
    local -a records=()
    local line key name value label

    while IFS=$'\t' read -r key name value label; do
        [[ -n $key ]] || continue
        records+=("${key}"$'\t'"${name}"$'\t'"${value}"$'\t'"${label}")
        name_counts["$name"]=$((${name_counts["$name"]:-0} + 1))
    done

    for line in "${records[@]}"; do
        IFS=$'\t' read -r key name value label <<<"$line"
        if ((${name_counts["$name"]:-0} > 1)); then
            # The trailing key segment is the sensor number, which is what
            # actually distinguishes them.
            printf '%s\t%s (%s)\t%s\n' "$key" "$name" "${key##*_}" "$value"
        else
            printf '%s\t%s\t%s\n' "$key" "$name" "$value"
        fi
    done
}

# Public entry point. Emits key<TAB>name<TAB>celsius, one sensor per line.
sensors_collect_temperatures() {
    local raw
    raw=$(sensors_collect_hwmon)

    # Fall back on "no readings" rather than "no hwmon directory": a machine
    # can have hwmon chips that expose no temperatures at all, such as a laptop
    # with only a battery sensor.
    if [[ -z $raw ]]; then
        raw=$(sensors_collect_thermal_zones)
    fi

    [[ -n $raw ]] || return 0

    printf '%s\n' "$raw" | sensors_disambiguate_names
}
