#!/usr/bin/env bash
# Tests for temperature collection, run against fake /sys trees.
#
# Fixtures rather than the live machine: the real /sys differs on every box, so
# asserting against it would either be vacuous or fail on the next machine. The
# "typical" fixture reproduces readings captured from a real AMD desktop,
# including every awkward case it exhibited.

source "${REPO_ROOT}/lib/sensors.sh"

FIXTURES="${REPO_ROOT}/tests/fixtures"

# Collector output is `key<TAB>display name<TAB>celsius` per line.
collect_from() {
    SYSFS_ROOT="$1" sensors_collect_temperatures
}

keys_from() {
    collect_from "$1" | cut -f1 | sort
}

value_of() {
    collect_from "$1" | awk -F'\t' -v k="$2" '$1 == k { print $3 }'
}

name_of() {
    collect_from "$1" | awk -F'\t' -v k="$2" '$1 == k { print $2 }'
}

names_from() {
    collect_from "$1" | cut -f2
}

# Entity keys intentionally identify a sensor by chip and number, not by label:
# labels are driver strings that change across kernel versions, and a key change
# orphans an entity's history in Home Assistant. Label assertions therefore
# belong on display names, which is where labels are actually used.
key_for_label() {
    collect_from "$1" | awk -F'\t' -v l="$2" 'tolower($2) ~ tolower(l) { print $1 }'
}

# --------------------------------------------------------------------------
# Identity and uniqueness
# --------------------------------------------------------------------------

test_every_entity_key_is_unique() {
    # If keys collide, sensors silently overwrite each other in Home Assistant
    # and readings appear to jump between unrelated hardware.
    local total unique
    total=$(collect_from "${FIXTURES}/sysfs-typical" | wc -l)
    unique=$(keys_from "${FIXTURES}/sysfs-typical" | uniq | wc -l)
    assert_eq "$total" "$unique" "entity keys must be unique" || return 1
}

test_two_chips_with_the_same_name_stay_distinct() {
    # Both NVMe drives report chip name "nvme" and a sensor labelled
    # "Composite". Only the device path distinguishes them.
    local count
    count=$(keys_from "${FIXTURES}/sysfs-typical" | grep -c nvme)
    assert_eq "6" "$count" "expected 3 sensors from each of the 2 nvme chips" || return 1

    # Each drive must carry its own reading rather than one shadowing the other.
    assert_eq "53.9" "$(value_of "${FIXTURES}/sysfs-typical" nvme_nvme0_temp1)" \
        "first drive's Composite temperature" || return 1
    assert_eq "32.9" "$(value_of "${FIXTURES}/sysfs-typical" nvme_nvme1_temp1)" \
        "second drive's Composite temperature" || return 1
}

test_sensors_sharing_a_label_get_distinct_keys() {
    # nct6797 exposes five sensors all labelled "Virtual_TEMP". They must
    # survive as five separate entities rather than collapsing into one.
    local count unique
    count=$(key_for_label "${FIXTURES}/sysfs-typical" 'virtual_temp' | wc -l)
    unique=$(key_for_label "${FIXTURES}/sysfs-typical" 'virtual_temp' | sort -u | wc -l)
    assert_eq "5" "$count" "all five Virtual_TEMP sensors must be collected" || return 1
    assert_eq "5" "$unique" "their keys must all be distinct" || return 1
}

test_entity_keys_are_slugified() {
    # Keys end up in MQTT topics and HA entity ids, so anything outside
    # [a-z0-9_] will cause trouble somewhere downstream.
    local bad
    bad=$(keys_from "${FIXTURES}/sysfs-typical" | grep -vE '^[a-z0-9_]+$' || true)
    assert_eq "" "$bad" "keys must contain only lowercase alphanumerics and underscores" || return 1
}

test_keys_are_stable_across_runs() {
    local first second
    first=$(keys_from "${FIXTURES}/sysfs-typical")
    second=$(keys_from "${FIXTURES}/sysfs-typical")
    assert_eq "$first" "$second" "collection must be deterministic" || return 1
}

test_keys_do_not_depend_on_hwmon_enumeration_index() {
    # hwmonN numbering is enumeration order and can shuffle across reboots. If
    # keys embedded it, a reboot could rename every entity in HA and orphan its
    # history. Chips with a device link must key off that link instead.
    local bad
    bad=$(keys_from "${FIXTURES}/sysfs-typical" | grep -E '(^|_)hwmon[0-9]' | grep -v '^acpitz' || true)
    assert_eq "" "$bad" "chips with a device link must not embed the hwmon index" || return 1
}

test_chip_without_device_link_falls_back_to_hwmon_index() {
    # acpitz in the fixture has no device symlink, so there is nothing stable to
    # key off and the hwmon index is the only option. Asserted explicitly so the
    # limitation is visible rather than looking like an oversight.
    assert_contains "$(keys_from "${FIXTURES}/sysfs-typical")" "acpitz_hwmon6" || return 1
}

# --------------------------------------------------------------------------
# Filtering
# --------------------------------------------------------------------------

test_impossible_readings_are_dropped() {
    # AUXTIN1 reads -128000 (-128 C) from an unconnected pin. Reporting that to
    # HA produces an alarming, meaningless graph.
    assert_eq "" "$(key_for_label "${FIXTURES}/sysfs-typical" 'auxtin1')" \
        "-128 C is not a temperature and should be filtered" || return 1

    # A plausible reading from the same chip must survive, proving the filter
    # acts on the value rather than blacklisting the chip.
    assert_contains "$(names_from "${FIXTURES}/sysfs-typical")" "AUXTIN2" \
        "valid AUXTIN2 reading should be kept" || return 1
}

test_slightly_negative_readings_are_kept() {
    # AUXTIN3 reads -1000 (-1.0 C). That is very likely an unconnected pin, but
    # it is indistinguishable by value from a genuine sub-zero reading, and
    # nodes in garages, lofts and outbuildings do read below freezing in winter.
    #
    # Silently discarding real cold readings is the worse failure: it produces a
    # sensor that quietly stops reporting exactly when the temperature gets
    # interesting. Chips known to be noisy are pruned via IGNORE_PATTERN
    # instead, which is a decision the operator can make and we cannot.
    assert_contains "$(names_from "${FIXTURES}/sysfs-typical")" "AUXTIN3" \
        "-1 C is a plausible temperature and must not be silently dropped" || return 1
}

test_zero_readings_are_dropped() {
    # amdgpu's "mem" sensor reads exactly 0 when idle, which is not a real
    # temperature.
    assert_not_contains "$(keys_from "${FIXTURES}/sysfs-typical")" "mem" || return 1
}

test_peripheral_batteries_are_ignored() {
    # A wireless mouse appears in hwmon as hidpp_battery_0. It is not a node.
    assert_not_contains "$(keys_from "${FIXTURES}/sysfs-typical")" "hidpp" || return 1
}

test_ignore_pattern_is_configurable() {
    local keys
    keys=$(SYSFS_ROOT="${FIXTURES}/sysfs-typical" IGNORE_PATTERN='nvme' sensors_collect_temperatures | cut -f1)
    assert_not_contains "$keys" "nvme" "user ignore pattern should exclude nvme" || return 1
    assert_contains "$keys" "k10temp" "unrelated chips should remain" || return 1
}

test_valid_readings_are_not_over_filtered() {
    # Guard against a filter so aggressive it silently reports nothing useful.
    local keys names
    keys=$(keys_from "${FIXTURES}/sysfs-typical")
    names=$(names_from "${FIXTURES}/sysfs-typical")
    assert_contains "$keys" "k10temp" || return 1
    assert_contains "$keys" "amdgpu" || return 1
    assert_contains "$names" "SYSTIN" || return 1
    assert_contains "$names" "CPUTIN" || return 1
}

# --------------------------------------------------------------------------
# Values
# --------------------------------------------------------------------------

test_millidegrees_are_converted_to_celsius() {
    # 70125 millidegrees -> 70.1 C, using integer arithmetic since bc is not
    # guaranteed to be installed.
    local key value
    key=$(keys_from "${FIXTURES}/sysfs-typical" | grep k10temp | head -1)
    value=$(value_of "${FIXTURES}/sysfs-typical" "$key")
    assert_contains "$value" "." "value should be a decimal" || return 1
}

test_tctl_reading_is_exact() {
    local key value
    key=$(collect_from "${FIXTURES}/sysfs-typical" | grep -i tctl | cut -f1)
    value=$(value_of "${FIXTURES}/sysfs-typical" "$key")
    assert_eq "70.1" "$value" "70125 millidegrees should render as 70.1" || return 1
}

test_rounding_is_correct_at_boundaries() {
    assert_eq "53.9" "$(sensors_millidegrees_to_celsius 53850)" "53850 rounds to 53.9" || return 1
    assert_eq "32.9" "$(sensors_millidegrees_to_celsius 32850)" "32850 rounds to 32.9" || return 1
    assert_eq "46.0" "$(sensors_millidegrees_to_celsius 46000)" "46000 is exactly 46.0" || return 1
    assert_eq "70.1" "$(sensors_millidegrees_to_celsius 70125)" "70125 truncates/rounds to 70.1" || return 1
}

test_negative_temperatures_are_handled() {
    # Cold-climate nodes and outdoor sensors genuinely read below zero, so the
    # sanity filter must not simply reject everything negative.
    assert_eq "-5.5" "$(sensors_millidegrees_to_celsius -5500)" "negative values must keep their sign" || return 1
    assert_eq "-12.0" "$(sensors_millidegrees_to_celsius -12000)" || return 1
}

# --------------------------------------------------------------------------
# Display names
# --------------------------------------------------------------------------

test_display_name_includes_chip_and_label() {
    local key name
    key=$(collect_from "${FIXTURES}/sysfs-typical" | grep -i tctl | cut -f1)
    name=$(name_of "${FIXTURES}/sysfs-typical" "$key")
    assert_contains "$name" "Tctl" "display name should include the sensor label" || return 1
    assert_contains "$name" "k10temp" "display name should include the chip" || return 1
}

test_duplicate_labels_get_disambiguated_names() {
    # Five identical "Virtual_TEMP" names in the HA UI would be unusable.
    local names unique_count
    names=$(collect_from "${FIXTURES}/sysfs-typical" | grep -i virtual | cut -f2)
    unique_count=$(printf '%s\n' "$names" | sort -u | wc -l)
    assert_eq "5" "$unique_count" "duplicate labels must produce distinct display names" || return 1
}

test_unlabelled_sensors_still_get_a_name() {
    local name
    name=$(collect_from "${FIXTURES}/sysfs-typical" | grep acpitz | cut -f2)
    assert_contains "$name" "acpitz" "unlabelled sensors should fall back to the chip name" || return 1
}

# --------------------------------------------------------------------------
# Fallbacks and degradation
# --------------------------------------------------------------------------

test_thermal_zone_fallback_when_no_hwmon_temperatures() {
    # Common on ARM boards and some VMs.
    local keys
    keys=$(keys_from "${FIXTURES}/sysfs-thermal-only")
    assert_contains "$keys" "x86_pkg_temp" "thermal zones should be used when hwmon has no temps" || return 1
    assert_eq "48.0" "$(value_of "${FIXTURES}/sysfs-thermal-only" "$(printf '%s' "$keys" | grep x86_pkg | head -1)")" || return 1
}

test_machine_with_no_sensors_produces_no_output_and_no_error() {
    local output status
    output=$(collect_from "${FIXTURES}/sysfs-empty")
    status=$?
    assert_eq "0" "$status" "a sensorless machine must not be an error" || return 1
    assert_eq "" "$output" "a sensorless machine should report nothing" || return 1
}

test_sparse_temp_numbering_is_handled() {
    # k10temp exposes temp1, temp3 and temp4 with no temp2. A loop assuming a
    # contiguous 1..N range would stop early and silently lose the per-CCD
    # sensors — the failure would look like missing hardware, not a bug.
    local names
    names=$(names_from "${FIXTURES}/sysfs-typical")
    assert_contains "$names" "Tccd1" || return 1
    assert_contains "$names" "Tccd2" || return 1
    assert_contains "$(keys_from "${FIXTURES}/sysfs-typical")" "k10temp_0000_00_18_3_temp4" || return 1
}
