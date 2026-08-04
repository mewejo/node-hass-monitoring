#!/usr/bin/env bash
# Tests for Home Assistant MQTT discovery payload generation.
#
# These assert against the discovery schema Home Assistant documents, not
# against our own output, so a malformed payload cannot pass by matching a
# golden file captured from the same bug.

source "${REPO_ROOT}/lib/discovery.sh"

FIXTURES="${REPO_ROOT}/tests/fixtures"

NODE_ID=testnode
NODE_NAME=testnode
DISCOVERY_PREFIX=homeassistant
STATE_TOPIC="nodemon/testnode/state"
INTERVAL=60
AGENT_VERSION=1.0.0

config_for() {
    discovery_config_payload "$1" "$2"
}

# --------------------------------------------------------------------------
# Discovery config payloads
# --------------------------------------------------------------------------

test_config_payload_is_valid_json() {
    local payload
    payload=$(config_for "k10temp_temp1" "k10temp Tctl")
    if ! printf '%s' "$payload" | python3 -m json.tool >/dev/null 2>&1; then
        _fail "discovery payload is not valid JSON:
$payload"
        return 1
    fi
}

test_config_declares_temperature_device_class() {
    # Without device_class, HA will not give the entity a temperature icon,
    # unit conversion, or a place in temperature-based automations.
    local payload
    payload=$(config_for "k10temp_temp1" "k10temp Tctl")
    assert_eq "temperature" "$(json_get "$payload" 'device_class')" || return 1
}

test_config_declares_measurement_state_class() {
    # state_class=measurement is what makes HA record long-term statistics.
    # Without it the sensor has no history beyond the recorder purge window.
    local payload
    payload=$(config_for "k10temp_temp1" "k10temp Tctl")
    assert_eq "measurement" "$(json_get "$payload" 'state_class')" || return 1
}

test_config_uses_celsius() {
    local payload
    payload=$(config_for "k10temp_temp1" "k10temp Tctl")
    assert_eq "°C" "$(json_get "$payload" 'unit_of_measurement')" || return 1
}

test_unique_id_is_namespaced_by_node() {
    # Two machines both have a k10temp Tctl. If unique_id is not namespaced,
    # the second node's discovery overwrites the first node's entity.
    local payload unique_id
    payload=$(config_for "k10temp_temp1" "k10temp Tctl")
    unique_id=$(json_get "$payload" 'unique_id')
    assert_contains "$unique_id" "testnode" "unique_id must include the node id" || return 1
    assert_contains "$unique_id" "k10temp_temp1" "unique_id must include the entity key" || return 1
}

test_config_points_at_the_shared_state_topic() {
    local payload
    payload=$(config_for "k10temp_temp1" "k10temp Tctl")
    assert_eq "nodemon/testnode/state" "$(json_get "$payload" 'state_topic')" || return 1
}

test_value_template_extracts_this_entitys_key() {
    # All sensors share one state topic, so each entity needs a template that
    # picks out its own key.
    local payload template
    payload=$(config_for "k10temp_temp1" "k10temp Tctl")
    template=$(json_get "$payload" 'value_template')
    assert_contains "$template" "value_json.k10temp_temp1" || return 1
}

test_expire_after_exceeds_the_publish_interval() {
    # This is how a dead node shows as unavailable. Set it below the interval
    # and every sensor flaps to unavailable between normal updates.
    local payload expire
    payload=$(config_for "k10temp_temp1" "k10temp Tctl")
    expire=$(json_get "$payload" 'expire_after')
    if ((expire <= INTERVAL)); then
        _fail "expire_after ($expire) must exceed the publish interval ($INTERVAL)"
        return 1
    fi
}

test_all_entities_share_one_device() {
    # Identical device identifiers are what group every sensor under a single
    # device in HA rather than scattering them as standalone entities.
    local a b
    a=$(json_get "$(config_for 'k10temp_temp1' 'k10temp Tctl')" 'device.identifiers.0')
    b=$(json_get "$(config_for 'amdgpu_temp1' 'amdgpu edge')" 'device.identifiers.0')
    assert_eq "$a" "$b" "all sensors must belong to the same device" || return 1
    assert_contains "$a" "testnode" || return 1
}

test_device_is_named_after_the_host() {
    local payload
    payload=$(config_for "k10temp_temp1" "k10temp Tctl")
    assert_eq "testnode" "$(json_get "$payload" 'device.name')" || return 1
}

test_entity_name_is_the_sensor_label_only() {
    # HA prefixes the device name automatically, so repeating the hostname here
    # yields "testnode testnode k10temp Tctl" in the UI.
    local payload
    payload=$(config_for "k10temp_temp1" "k10temp Tctl")
    assert_eq "k10temp Tctl" "$(json_get "$payload" 'name')" || return 1
}

test_payload_with_quotes_in_name_stays_valid_json() {
    # Sensor labels come from kernel drivers and are not guaranteed benign.
    local payload
    payload=$(config_for "odd_temp1" 'chip "quoted" \label')
    if ! printf '%s' "$payload" | python3 -m json.tool >/dev/null 2>&1; then
        _fail "unescaped characters in a sensor label broke the JSON:
$payload"
        return 1
    fi
}

test_config_topic_follows_ha_discovery_convention() {
    # <prefix>/sensor/<node>/<entity>/config is what HA watches.
    local topic
    topic=$(discovery_config_topic "k10temp_temp1")
    assert_eq "homeassistant/sensor/nodemon_testnode/k10temp_temp1/config" "$topic" || return 1
}

# --------------------------------------------------------------------------
# State payload
# --------------------------------------------------------------------------

test_state_payload_is_valid_json() {
    local payload
    payload=$(printf 'a\tA\t1.5\nb\tB\t2.5\n' | discovery_state_payload)
    if ! printf '%s' "$payload" | python3 -m json.tool >/dev/null 2>&1; then
        _fail "state payload is not valid JSON: $payload"
        return 1
    fi
}

test_state_payload_maps_keys_to_values() {
    local payload
    payload=$(printf 'a\tA\t1.5\nb\tB\t2.5\n' | discovery_state_payload)
    assert_eq "1.5" "$(json_get "$payload" 'a')" || return 1
    assert_eq "2.5" "$(json_get "$payload" 'b')" || return 1
}

test_state_values_are_json_numbers_not_strings() {
    # Quoted numbers make HA treat the sensor as a string, which breaks
    # statistics and any numeric automation downstream.
    local payload
    payload=$(printf 'a\tA\t1.5\n' | discovery_state_payload)
    assert_not_contains "$payload" '"1.5"' "values must not be quoted" || return 1
}

test_empty_sensor_list_produces_empty_json_object() {
    local payload
    payload=$(printf '' | discovery_state_payload)
    assert_eq "{}" "$payload" || return 1
}

test_negative_values_survive_the_state_payload() {
    local payload
    payload=$(printf 'cold\tCold\t-5.5\n' | discovery_state_payload)
    assert_eq "-5.5" "$(json_get "$payload" 'cold')" || return 1
}

# --------------------------------------------------------------------------
# End-to-end payload generation from real fixtures
# --------------------------------------------------------------------------

test_full_fixture_produces_valid_payloads_for_every_sensor() {
    local records key name value bad=0
    records=$(SYSFS_ROOT="${FIXTURES}/sysfs-typical" bash -c "
        source '${REPO_ROOT}/lib/sensors.sh'; sensors_collect_temperatures")

    while IFS=$'\t' read -r key name value; do
        [[ -n $key ]] || continue
        if ! config_for "$key" "$name" | python3 -m json.tool >/dev/null 2>&1; then
            _fail "invalid discovery JSON for key=$key name=$name"
            bad=1
        fi
    done <<<"$records"

    ((bad == 0)) || return 1
}

test_full_fixture_state_payload_is_valid() {
    local payload count
    payload=$(SYSFS_ROOT="${FIXTURES}/sysfs-typical" bash -c "
        source '${REPO_ROOT}/lib/sensors.sh'; sensors_collect_temperatures" | discovery_state_payload)

    if ! printf '%s' "$payload" | python3 -m json.tool >/dev/null 2>&1; then
        _fail "state payload from real fixture is not valid JSON: $payload"
        return 1
    fi

    # Sanity check that it is not trivially empty.
    count=$(printf '%s' "$payload" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
    if ((count < 15)); then
        _fail "expected many sensors from the typical fixture, got $count"
        return 1
    fi
}
