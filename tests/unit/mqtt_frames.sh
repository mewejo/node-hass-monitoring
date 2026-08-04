#!/usr/bin/env bash
# Byte-level tests for the pure-bash MQTT client.
#
# Expected values here are derived from the MQTT 3.1.1 specification, not from
# our own implementation's output. That direction matters: a golden file
# captured from the code under test would happily confirm a bug. Real-broker
# acceptance is proved separately in tests/integration.

source "${REPO_ROOT}/lib/mqtt.sh"

# MQTT 3.1.1 §2.2.3 gives these exact remaining-length encodings.
test_varint_spec_vectors() {
    assert_bytes "00" "$(mqtt_encode_varint 0)" "0 encodes to one byte" || return 1
    assert_bytes "7f" "$(mqtt_encode_varint 127)" "127 is the one-byte maximum" || return 1
    assert_bytes "80 01" "$(mqtt_encode_varint 128)" "128 is the two-byte minimum" || return 1
    assert_bytes "ff 7f" "$(mqtt_encode_varint 16383)" "16383 is the two-byte maximum" || return 1
    assert_bytes "80 80 01" "$(mqtt_encode_varint 16384)" "16384 is the three-byte minimum" || return 1
    assert_bytes "ff ff 7f" "$(mqtt_encode_varint 2097151)" "2097151 is the three-byte maximum" || return 1
}

# Regression guard. `local s=$1 len=${#s}` silently reads an outer-scope `s`,
# because bash expands every word of a `local` before assigning any of them.
# That produced a zero length prefix for every string in every packet, and only
# showed up because a leftover global made an early manual check pass.
test_length_prefix_is_independent_of_outer_scope() {
    # shellcheck disable=SC2034 # deliberately shadowing to reproduce the bug
    local s="a-much-longer-outer-value"
    assert_bytes "00 01 63" "$(mqtt_string 'c')" "length prefix must come from the argument" || return 1

    unset s
    assert_bytes "00 01 63" "$(mqtt_string 'c')" "length prefix must be correct with no outer s" || return 1
}

test_length_prefix_is_big_endian_over_255_bytes() {
    local long
    long=$(printf '%0.sA' {1..300})
    # 300 = 0x012c, so the prefix is 01 2c.
    assert_eq "01 2c" "$(hex_of "$(mqtt_string "$long")" | cut -d' ' -f1-2)" \
        "two-byte length must be big-endian" || return 1
}

test_publish_qos0_frame() {
    # 0x30 = PUBLISH, QoS 0, no retain. Remaining length 7 = 2 topic-length
    # bytes + 3 topic bytes + 2 payload bytes. No packet identifier at QoS 0.
    assert_bytes "30 07 00 03 61 2f 62 68 69" "$(mqtt_build_publish 'a/b' 'hi' 0)" || return 1
}

test_publish_retain_flag_sets_low_bit() {
    assert_bytes "31 07 00 03 61 2f 62 68 69" "$(mqtt_build_publish 'a/b' 'hi' 1)" || return 1
}

test_publish_empty_payload_is_valid() {
    # An empty retained payload is how a discovery config is cleared, so this
    # frame has to be exactly right or stale entities linger in HA forever.
    assert_bytes "31 05 00 03 61 2f 62" "$(mqtt_build_publish 'a/b' '' 1)" || return 1
}

test_publish_large_payload_uses_multibyte_varint() {
    local payload
    payload=$(printf '%0.sA' {1..200})
    # 2 topic-length bytes + 1 topic byte + 200 payload bytes = 203 = 0xcb.
    assert_eq "30 cb 01 00 01 74" "$(hex_of "$(mqtt_build_publish 't' "$payload")" | cut -d' ' -f1-6)" \
        "payloads over 127 bytes need a two-byte remaining length" || return 1
}

test_publish_payload_bytes_survive_verbatim() {
    # JSON payloads contain quotes, backslashes and percent signs; all three
    # are printf hazards if the escaping is wrong.
    local payload='{"a":"100%","b":"c\\d","c":"\"q\""}'
    local round_trip
    round_trip=$(printf '%b' "$(mqtt_escape "$payload")")
    assert_eq "$payload" "$round_trip" "payload must survive escaping byte for byte" || return 1
}

test_connect_frame_without_auth() {
    # 0x10 CONNECT, remaining length 13, protocol name "MQTT", level 4,
    # flags 0x02 (clean session), keepalive 0, client id "c".
    assert_bytes "10 0d 00 04 4d 51 54 54 04 02 00 00 00 01 63" \
        "$(mqtt_build_connect 'c')" || return 1
}

test_connect_frame_sets_username_and_password_flags() {
    # flags 0xc2 = username (0x80) | password (0x40) | clean session (0x02).
    assert_bytes "10 13 00 04 4d 51 54 54 04 c2 00 00 00 01 63 00 01 75 00 01 70" \
        "$(mqtt_build_connect 'c' 'u' 'p')" || return 1
}

test_connect_username_without_password_sets_only_username_flag() {
    # Byte 10 is the connect flags: 0x82 = username | clean session, with no
    # password bit. (Byte 9 is the protocol level, 0x04.)
    assert_eq "82" "$(hex_of "$(mqtt_build_connect 'c' 'u')" | cut -d' ' -f10)" || return 1
}

test_disconnect_frame() {
    assert_bytes "e0 00" "$(mqtt_build_disconnect)" || return 1
}

test_connack_messages_are_human_readable() {
    assert_contains "$(mqtt_connack_message 4)" "bad username or password" || return 1
    assert_contains "$(mqtt_connack_message 5)" "not authorised" || return 1
    assert_contains "$(mqtt_connack_message 0)" "accepted" || return 1
}

test_closing_the_connection_does_not_silence_the_shells_stderr() {
    # Regression guard. mqtt_close used `exec {fd}>&- 2>/dev/null`, but a bare
    # `exec` applies its redirections permanently to the current shell, so that
    # sent all subsequent stderr to /dev/null. Every log line and every error
    # message after a successful publish silently disappeared -- the agent
    # looked like it was doing nothing while working perfectly.
    local output
    output=$(
        {
            mqtt_close
            printf 'stderr-still-works\n' >&2
        } 2>&1
    )
    assert_contains "$output" "stderr-still-works" \
        "mqtt_close must not redirect the caller's stderr" || return 1
}

test_connect_to_closed_port_fails_without_hanging() {
    # A monitored node must fail fast rather than wedge the systemd timer.
    # Port 1 is reserved and never listening.
    if mqtt_connect 127.0.0.1 1 test-client 2>/dev/null; then
        _fail "connecting to a closed port should fail"
        return 1
    fi
    assert_contains "$mqtt_last_error" "cannot connect" || return 1
}
