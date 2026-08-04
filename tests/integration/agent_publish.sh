#!/usr/bin/env bash
# End-to-end tests: agent.sh publishing to a real broker, verified with the
# real mosquitto_sub client.
#
# Uses the fixture sysfs trees rather than the host's real sensors, so the
# assertions are deterministic on any machine and in CI.
#
# Requires: scripts/dev-broker.sh up

BROKER_HOST=127.0.0.1
BROKER_PORT=1883
MOSQ_IMAGE=eclipse-mosquitto:2.0.22
FIXTURES="${REPO_ROOT}/tests/fixtures"

# Each test gets its own node id and state dir, so retained topics and entity
# bookkeeping from one test cannot leak into another.
setup_env() {
    TEST_NODE="ci$$${RANDOM}"
    TEST_STATE_DIR=$(mktemp -d)
    TEST_CONFIG=$(mktemp)

    cat >"$TEST_CONFIG" <<EOF
MQTT_HOST=${BROKER_HOST}
MQTT_PORT=${BROKER_PORT}
MQTT_USERNAME=
MQTT_PASSWORD=
MQTT_TLS=0
DISCOVERY_PREFIX=homeassistant
INTERVAL=60
EOF
}

teardown_env() {
    rm -rf "$TEST_STATE_DIR" "$TEST_CONFIG"
}

run_agent() {
    local sysfs=$1
    shift
    SYSFS_ROOT="${FIXTURES}/${sysfs}" \
        CONFIG_FILE="$TEST_CONFIG" \
        STATE_DIR="$TEST_STATE_DIR" \
        NODE_NAME="$TEST_NODE" \
        "${REPO_ROOT}/agent.sh" "$@" 2>&1
}

# Read a retained topic with the genuine mosquitto client.
sub_retained() {
    docker run --rm --network host "$MOSQ_IMAGE" \
        mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" \
        -t "$1" -F '%p' -W "${2:-2}" 2>/dev/null
}

count_retained() {
    docker run --rm --network host "$MOSQ_IMAGE" \
        mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" \
        -t "$1" -F '%t' -W "${2:-2}" 2>/dev/null | grep -c . || true
}

cleanup_node() {
    run_agent sysfs-typical --clear >/dev/null 2>&1 || true
}

# --------------------------------------------------------------------------

test_agent_publishes_state_to_broker() {
    setup_env
    run_agent sysfs-typical >/dev/null || {
        teardown_env
        _fail "agent run failed"
        return 1
    }

    local state
    state=$(sub_retained "nodemon/${TEST_NODE}/state")

    # State is published without retain, so re-reading it after the fact
    # returns nothing. The discovery configs are the retained ones.
    local config_count
    config_count=$(count_retained "homeassistant/sensor/nodemon_${TEST_NODE}/+/config")

    cleanup_node
    teardown_env

    if ((config_count < 15)); then
        _fail "expected a discovery config per sensor, saw ${config_count}"
        return 1
    fi
}

test_discovery_configs_are_retained_and_valid_json() {
    setup_env
    run_agent sysfs-typical >/dev/null

    local payload
    payload=$(sub_retained "homeassistant/sensor/nodemon_${TEST_NODE}/k10temp_0000_00_18_3_temp1/config")

    cleanup_node
    teardown_env

    if [[ -z $payload ]]; then
        _fail "discovery config was not retained at the broker"
        return 1
    fi
    if ! printf '%s' "$payload" | python3 -m json.tool >/dev/null 2>&1; then
        _fail "retained discovery config is not valid JSON: $payload"
        return 1
    fi
    assert_eq "temperature" "$(json_get "$payload" 'device_class')" || return 1
}

test_state_payload_reaches_broker_with_live_values() {
    setup_env

    # Subscribe first, because the state message is not retained.
    local logfile
    logfile=$(mktemp)
    docker run --rm -d --name "hnm-state-$$" --network host "$MOSQ_IMAGE" \
        mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" -t "nodemon/${TEST_NODE}/state" -F '%p' >/dev/null
    sleep 1

    run_agent sysfs-typical >/dev/null
    sleep 1

    local state
    state=$(docker logs "hnm-state-$$" 2>/dev/null | tail -1)
    docker rm -f "hnm-state-$$" >/dev/null 2>&1
    rm -f "$logfile"
    cleanup_node
    teardown_env

    if [[ -z $state ]]; then
        _fail "no state message received"
        return 1
    fi
    if ! printf '%s' "$state" | python3 -m json.tool >/dev/null 2>&1; then
        _fail "state payload is not valid JSON: $state"
        return 1
    fi
    # Tctl in the fixture is 70125 millidegrees.
    assert_eq "70.1" "$(json_get "$state" 'k10temp_0000_00_18_3_temp1')" || return 1
}

test_removed_hardware_clears_its_stale_entity() {
    # The GPU is present on the first run and gone on the second. Its discovery
    # config is retained, so without explicit cleanup the entity would linger in
    # Home Assistant forever as a permanently-unavailable ghost.
    setup_env

    run_agent sysfs-typical >/dev/null
    local before
    before=$(sub_retained "homeassistant/sensor/nodemon_${TEST_NODE}/amdgpu_0000_0c_00_0_temp1/config")

    if [[ -z $before ]]; then
        cleanup_node
        teardown_env
        _fail "setup failed: GPU entity was never published"
        return 1
    fi

    run_agent sysfs-gpu-removed >/dev/null
    local after
    after=$(sub_retained "homeassistant/sensor/nodemon_${TEST_NODE}/amdgpu_0000_0c_00_0_temp1/config")

    # Sensors that still exist must be untouched.
    local survivor
    survivor=$(sub_retained "homeassistant/sensor/nodemon_${TEST_NODE}/k10temp_0000_00_18_3_temp1/config")

    cleanup_node
    teardown_env

    assert_eq "" "$after" "removed GPU's discovery config should have been cleared" || return 1
    if [[ -z $survivor ]]; then
        _fail "cleanup wrongly removed a sensor that still exists"
        return 1
    fi
}

test_clear_removes_every_entity() {
    setup_env
    run_agent sysfs-typical >/dev/null

    local before after
    before=$(count_retained "homeassistant/sensor/nodemon_${TEST_NODE}/+/config")
    run_agent sysfs-typical --clear >/dev/null
    after=$(count_retained "homeassistant/sensor/nodemon_${TEST_NODE}/+/config")

    teardown_env

    if ((before < 15)); then
        _fail "setup failed: expected many entities, saw ${before}"
        return 1
    fi
    assert_eq "0" "$after" "--clear must remove every retained discovery config" || return 1
}

test_discovery_is_not_republished_when_sensor_set_is_unchanged() {
    # Retained configs persist at the broker, so resending identical ones every
    # cycle is pure noise: 23 needless retained publishes every minute, forever.
    setup_env

    local first second
    first=$(run_agent sysfs-typical)
    second=$(run_agent sysfs-typical)

    cleanup_node
    teardown_env

    assert_contains "$first" "discovery refreshed" "first run should publish discovery" || return 1
    assert_not_contains "$second" "discovery refreshed" \
        "second identical run should skip discovery" || return 1
}

test_concurrent_runs_do_not_disconnect_each_other() {
    # MQTT brokers disconnect an existing client when a new one connects with
    # the same client ID. A manual `systemctl start` overlapping a timer firing
    # would then kick the other off mid-publish and lose its readings, while
    # both runs still reported success -- a QoS 0 publish into a socket the
    # broker has already closed raises no error locally.
    setup_env

    run_agent sysfs-typical >/dev/null 2>&1

    # Subscribe first, because state messages are not retained, then run two
    # agents overlapping in time and count how many readings actually arrive.
    docker run --rm -d --name "hnm-conc-$$" --network host "$MOSQ_IMAGE" \
        mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" -t "nodemon/${TEST_NODE}/state" -F '%p' >/dev/null
    sleep 1

    run_agent sysfs-typical >/dev/null 2>&1 &
    run_agent sysfs-typical >/dev/null 2>&1
    wait
    sleep 1

    local received
    received=$(docker logs "hnm-conc-$$" 2>/dev/null | grep -c . || true)
    docker rm -f "hnm-conc-$$" >/dev/null 2>&1

    cleanup_node
    teardown_env

    if ((received < 2)); then
        _fail "both concurrent runs should publish; only ${received} state message(s) arrived"
        return 1
    fi
}

test_agent_reports_a_readable_error_when_broker_is_unreachable() {
    setup_env
    sed -i 's/^MQTT_PORT=.*/MQTT_PORT=1/' "$TEST_CONFIG"

    local output status
    output=$(run_agent sysfs-typical)
    status=$?

    teardown_env

    if ((status == 0)); then
        _fail "agent should fail when the broker is unreachable"
        return 1
    fi
    assert_contains "$output" "cannot connect" || return 1
}

test_node_with_no_sensors_fails_loudly_rather_than_publishing_nothing() {
    # Silently publishing an empty device would look like success while the
    # node reports nothing at all.
    setup_env

    local output status
    output=$(run_agent sysfs-empty)
    status=$?

    teardown_env

    if ((status == 0)); then
        _fail "a node with no sensors should report failure"
        return 1
    fi
    assert_contains "$output" "no usable temperature sensors" || return 1
}

test_thermal_zone_only_node_publishes_successfully() {
    setup_env
    run_agent sysfs-thermal-only >/dev/null || {
        cleanup_node
        teardown_env
        _fail "thermal-zone-only node failed to publish"
        return 1
    }

    local count
    count=$(count_retained "homeassistant/sensor/nodemon_${TEST_NODE}/+/config")

    run_agent sysfs-thermal-only --clear >/dev/null 2>&1 || true
    teardown_env

    if ((count < 2)); then
        _fail "expected thermal zone sensors to be published, saw ${count}"
        return 1
    fi
}
