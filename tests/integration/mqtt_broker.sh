#!/usr/bin/env bash
# Integration tests for the pure-bash MQTT client against a real broker.
#
# The broker is genuine eclipse-mosquitto (see scripts/dev-broker.sh) and the
# verification client is genuine mosquitto_sub. Nothing on the far side of the
# wire is our own code, so these tests prove real MQTT interoperability rather
# than merely proving we are self-consistent.
#
# Requires: scripts/dev-broker.sh up

source "${REPO_ROOT}/lib/mqtt.sh"

BROKER_HOST=127.0.0.1
BROKER_PORT=1883
BROKER_AUTH_PORT=1884
BROKER_TLS_PORT=8883
BROKER_USER=testuser
BROKER_PASS=testpass
MOSQ_IMAGE=eclipse-mosquitto:2.0.22

# Subscribe with the real mosquitto client and print whatever is retained.
# -W bounds the wait so a missing message fails fast instead of hanging.
sub_retained() {
    local topic=$1 timeout=${2:-2}
    docker run --rm --network host "$MOSQ_IMAGE" \
        mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" \
        -t "$topic" -F '%p' -W "$timeout" 2>/dev/null
}

sub_retained_with_flag() {
    local topic=$1 timeout=${2:-2}
    docker run --rm --network host "$MOSQ_IMAGE" \
        mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" \
        -t "$topic" -F 'retain=%r %p' -W "$timeout" 2>/dev/null
}

# Unique topic per test run so tests never see each other's retained messages.
topic_for() {
    printf 'hnmtest/%s/%s' "$1" "$$"
}

publish_one() {
    local topic=$1 payload=$2 retain=${3:-0}
    mqtt_connect "$BROKER_HOST" "$BROKER_PORT" "hnm-test-$$" || return 1
    mqtt_publish "$topic" "$payload" "$retain"
    mqtt_disconnect
}

clear_topic() {
    mqtt_connect "$BROKER_HOST" "$BROKER_PORT" "hnm-clear-$$" || return 1
    mqtt_publish "$1" "" 1
    mqtt_disconnect
}

test_broker_is_running() {
    if ! (exec 3<>/dev/tcp/${BROKER_HOST}/${BROKER_PORT}) 2>/dev/null; then
        _fail "broker not reachable on ${BROKER_HOST}:${BROKER_PORT} — run: scripts/dev-broker.sh up"
        return 1
    fi
}

test_real_broker_accepts_our_connect_packet() {
    if ! mqtt_connect "$BROKER_HOST" "$BROKER_PORT" "hnm-connect-$$"; then
        _fail "real mosquitto rejected our CONNECT: $mqtt_last_error"
        return 1
    fi
    mqtt_disconnect
}

test_published_message_arrives_at_broker() {
    local topic
    topic=$(topic_for simple)
    publish_one "$topic" "hello" 1 || return 1
    assert_eq "hello" "$(sub_retained "$topic")" "message did not arrive intact" || return 1
    clear_topic "$topic"
}

test_retain_flag_is_honoured_by_broker() {
    local topic
    topic=$(topic_for retained)
    publish_one "$topic" "keepme" 1 || return 1
    # A subscriber connecting *after* the publish only receives the message if
    # the broker actually stored it, and reports retain=1 when replaying it.
    assert_contains "$(sub_retained_with_flag "$topic")" "retain=1 keepme" || return 1
    clear_topic "$topic"
}

test_empty_retained_payload_clears_the_topic() {
    # This is exactly how a stale HA entity gets removed, so it has to work.
    local topic
    topic=$(topic_for clearing)
    publish_one "$topic" "temporary" 1 || return 1
    assert_eq "temporary" "$(sub_retained "$topic")" "setup publish failed" || return 1

    clear_topic "$topic" || return 1
    assert_eq "" "$(sub_retained "$topic")" "retained topic should be empty after clearing" || return 1
}

test_payload_over_127_bytes_survives_the_wire() {
    # Proves the multi-byte remaining-length varint end to end, not just in a
    # unit test. Every HA discovery config exceeds this length.
    local topic payload received
    topic=$(topic_for large)
    payload=$(printf '%0.sX' {1..500})
    publish_one "$topic" "$payload" 1 || return 1
    received=$(sub_retained "$topic")
    assert_eq "${#payload}" "${#received}" "500-byte payload was truncated or corrupted" || return 1
    clear_topic "$topic"
}

test_json_payload_with_quotes_and_utf8_survives() {
    local topic payload
    topic=$(topic_for json)
    payload='{"temp":42.5,"unit":"°C","note":"a \"quoted\" value"}'
    publish_one "$topic" "$payload" 1 || return 1
    assert_eq "$payload" "$(sub_retained "$topic")" "JSON payload was corrupted in transit" || return 1
    clear_topic "$topic"
}

test_authenticated_listener_accepts_correct_credentials() {
    if ! mqtt_connect "$BROKER_HOST" "$BROKER_AUTH_PORT" "hnm-auth-$$" "$BROKER_USER" "$BROKER_PASS"; then
        _fail "correct credentials were rejected: $mqtt_last_error"
        return 1
    fi
    mqtt_disconnect
}

test_authenticated_listener_rejects_wrong_password() {
    # Note the broker returns CONNACK 5 (not authorised) rather than 4 here;
    # what matters is that we fail, and say so legibly.
    if mqtt_connect "$BROKER_HOST" "$BROKER_AUTH_PORT" "hnm-bad-$$" "$BROKER_USER" "wrongpass"; then
        mqtt_disconnect
        _fail "a wrong password was accepted"
        return 1
    fi
    assert_contains "$mqtt_last_error" "connection refused" || return 1
}

test_authenticated_listener_rejects_anonymous() {
    # Guards the broker config as much as the client: without
    # per_listener_settings, mosquitto applies allow_anonymous globally and this
    # listener silently stops checking credentials at all.
    if mqtt_connect "$BROKER_HOST" "$BROKER_AUTH_PORT" "hnm-anon-$$"; then
        mqtt_disconnect
        _fail "anonymous connection accepted on the authenticated listener"
        return 1
    fi
}

test_tls_listener_round_trip() {
    local topic
    topic=$(topic_for tls)

    MQTT_TLS_CAFILE="${REPO_ROOT}/tests/broker/certs/ca.crt"
    export MQTT_TLS_CAFILE

    if ! mqtt_connect localhost "$BROKER_TLS_PORT" "hnm-tls-$$" "" "" 1; then
        _fail "TLS connect failed: $mqtt_last_error"
        return 1
    fi
    mqtt_publish "$topic" "over-tls" 1
    mqtt_disconnect

    assert_eq "over-tls" "$(sub_retained "$topic")" "message published over TLS did not arrive" || return 1
    clear_topic "$topic"
}

test_connect_to_wrong_port_fails_fast() {
    # Port 22 accepts TCP but never speaks MQTT. Without a read timeout this
    # would hang forever and wedge the systemd timer on a real node.
    local start elapsed
    start=$SECONDS
    MQTT_READ_TIMEOUT=3
    export MQTT_READ_TIMEOUT

    if mqtt_connect "$BROKER_HOST" 22 "hnm-wrong-$$" 2>/dev/null; then
        mqtt_disconnect
        skip "nothing listening on 22 to test against"
        return 0
    fi

    elapsed=$((SECONDS - start))
    if ((elapsed > 10)); then
        _fail "took ${elapsed}s to give up; should fail fast"
        return 1
    fi
}
