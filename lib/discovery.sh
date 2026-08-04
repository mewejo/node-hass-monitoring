#!/usr/bin/env bash
# Home Assistant MQTT discovery payload generation.
#
# Uses the classic per-entity discovery format
# (<prefix>/sensor/<node>/<entity>/config) rather than the newer device-level
# format, because per-entity discovery works on every Home Assistant version
# while device-level discovery requires 2024.11 or later. On a fleet of home
# nodes, a silent failure on an older HA is a worse outcome than a slightly
# chattier set of retained topics.
#
# Sourceable with no side effects: this file only defines functions.
#
# Expects these to be set by the caller: NODE_ID, NODE_NAME, DISCOVERY_PREFIX,
# STATE_TOPIC, INTERVAL, AGENT_VERSION.

# Escape a string for inclusion in a JSON document.
#
# Sensor labels come from kernel drivers, not from us, and are not guaranteed to
# be free of quotes or backslashes. An unescaped one produces a malformed
# discovery payload that Home Assistant silently ignores, which presents as
# "some sensors just never appear" -- painful to diagnose after the fact.
discovery_json_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    printf '%s' "$s"
}

# The device block, repeated in every entity's config. Home Assistant merges
# entities into one device by matching identifiers, which is what makes a node
# appear as a single device with N temperature sensors rather than N loose
# entities.
discovery_device_block() {
    local model="" manufacturer=""

    # DMI gives a recognisable model on real hardware and something generic in a
    # VM. Absent entirely on most ARM boards, hence the guards.
    [[ -r /sys/class/dmi/id/product_name ]] && read -r model </sys/class/dmi/id/product_name 2>/dev/null
    [[ -r /sys/class/dmi/id/sys_vendor ]] && read -r manufacturer </sys/class/dmi/id/sys_vendor 2>/dev/null
    [[ -n $model ]] || model="Linux node"
    [[ -n $manufacturer ]] || manufacturer="unknown"

    printf '"device":{"identifiers":["nodemon_%s"],"name":"%s","model":"%s","manufacturer":"%s","sw_version":"%s"}' \
        "$(discovery_json_escape "$NODE_ID")" \
        "$(discovery_json_escape "$NODE_NAME")" \
        "$(discovery_json_escape "$model")" \
        "$(discovery_json_escape "$manufacturer")" \
        "$(discovery_json_escape "${AGENT_VERSION:-dev}")"
}

discovery_config_topic() {
    printf '%s/sensor/nodemon_%s/%s/config' "$DISCOVERY_PREFIX" "$NODE_ID" "$1"
}

# One entity's discovery config.
#
# Usage: discovery_config_payload <entity_key> <display_name>
discovery_config_payload() {
    local key=$1 name=$2

    # expire_after is how a dead node becomes visibly unavailable in HA. A
    # per-cycle connection cannot use an MQTT last-will for this: a will only
    # fires on an *ungraceful* disconnect, and we always disconnect cleanly, so
    # a will-based availability topic would never publish "offline" at all.
    #
    # Three intervals of slack absorbs a missed cycle or a slow broker without
    # flapping every sensor to unavailable between normal updates.
    local expire_after=$((INTERVAL * 3))

    printf '{'
    printf '"name":"%s",' "$(discovery_json_escape "$name")"
    printf '"unique_id":"nodemon_%s_%s",' "$(discovery_json_escape "$NODE_ID")" "$(discovery_json_escape "$key")"
    printf '"object_id":"%s_%s",' "$(discovery_json_escape "$NODE_ID")" "$(discovery_json_escape "$key")"
    printf '"state_topic":"%s",' "$(discovery_json_escape "$STATE_TOPIC")"
    printf '"value_template":"{{ value_json.%s }}",' "$key"
    printf '"device_class":"temperature",'
    # state_class is what makes Home Assistant keep long-term statistics.
    # Without it these sensors lose their history at the recorder purge.
    printf '"state_class":"measurement",'
    printf '"unit_of_measurement":"\\u00b0C",'
    printf '"suggested_display_precision":1,'
    printf '"expire_after":%d,' "$expire_after"
    printf '%s' "$(discovery_device_block)"
    printf '}'
}

# Build the single state payload carrying every sensor reading.
#
# One retained-free publish per cycle for all sensors, rather than one publish
# per sensor: on a node with 25 sensors that is 1 message instead of 25, and
# every entity's value_template reads its own key out of the same document.
#
# Reads key<TAB>name<TAB>value records on stdin.
discovery_state_payload() {
    local key name value first=1

    printf '{'
    while IFS=$'\t' read -r key name value; do
        [[ -n $key ]] || continue

        ((first)) || printf ','
        first=0

        # Values are emitted unquoted so Home Assistant sees JSON numbers.
        # Quoted numbers make HA treat the sensor as a string, which silently
        # breaks statistics and numeric automations.
        printf '"%s": %s' "$key" "$value"
    done

    printf '}'
}
