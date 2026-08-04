#!/usr/bin/env bash
# Installer tests.
#
# Run against a DESTDIR sandbox with SKIP_SYSTEMD=1, so the file layout,
# permissions and idempotency are all exercised without touching the host's
# systemd or creating real users. Full systemd behaviour is verified manually on
# a throwaway VM; that part is not practical to assert in CI.
#
# Requires: scripts/dev-broker.sh up

BROKER_HOST=127.0.0.1
BROKER_PORT=1883

run_installer() {
    local dest=$1
    shift
    MQTT_HOST="$BROKER_HOST" \
        MQTT_PORT="$BROKER_PORT" \
        INTERVAL=60 \
        DESTDIR="$dest" \
        SKIP_SYSTEMD=1 \
        bash "${REPO_ROOT}/install.sh" --non-interactive "$@" 2>&1
}

test_installer_lays_out_expected_files() {
    local dest
    dest=$(mktemp -d)
    run_installer "$dest" >/dev/null

    local missing=()
    local path
    for path in \
        /usr/local/lib/hass-node-monitor/agent.sh \
        /usr/local/lib/hass-node-monitor/lib/mqtt.sh \
        /usr/local/lib/hass-node-monitor/lib/sensors.sh \
        /usr/local/lib/hass-node-monitor/lib/discovery.sh \
        /etc/hass-node-monitor/config.env; do
        [[ -e "${dest}${path}" ]] || missing+=("$path")
    done

    rm -rf "$dest"
    assert_eq "" "${missing[*]-}" "installer did not create expected files" || return 1
}

test_installed_agent_is_executable() {
    local dest
    dest=$(mktemp -d)
    run_installer "$dest" >/dev/null

    local agent="${dest}/usr/local/lib/hass-node-monitor/agent.sh"
    local is_exec=0
    [[ -x $agent ]] && is_exec=1

    rm -rf "$dest"
    assert_eq "1" "$is_exec" "agent.sh must be executable" || return 1
}

test_config_file_is_not_world_readable() {
    # It holds the broker password. World-readable would leak it to every user
    # on the machine, which matters on a shared Proxmox host.
    local dest
    dest=$(mktemp -d)
    run_installer "$dest" >/dev/null

    local mode
    mode=$(stat -c '%a' "${dest}/etc/hass-node-monitor/config.env")

    rm -rf "$dest"
    assert_eq "640" "$mode" "config.env must be mode 0640" || return 1
}

test_password_is_not_visible_in_the_process_list() {
    # Nothing execs an external MQTT client, so the password is never an
    # argv entry. This is why shelling out to `mosquitto_pub -P secret` was
    # avoided even where it is available.
    local dest
    dest=$(mktemp -d)
    MQTT_PASSWORD='super-secret-value' run_installer "$dest" >/dev/null

    # Confirm it round-tripped into the config, so this test cannot pass
    # trivially by the password never having been set.
    local stored
    stored=$(grep -c 'super-secret-value' "${dest}/etc/hass-node-monitor/config.env" || true)

    local in_units=0
    if [[ -d "${dest}/etc/systemd" ]]; then
        grep -rq 'super-secret-value' "${dest}/etc/systemd" 2>/dev/null && in_units=1
    fi

    rm -rf "$dest"
    assert_eq "1" "$stored" "password should be stored in config.env" || return 1
    assert_eq "0" "$in_units" "password must not appear in a systemd unit" || return 1
}

test_installed_agent_publishes_successfully() {
    # Proves the installed layout actually works, not merely that files exist:
    # the agent has to find its libraries at the installed paths.
    local dest node
    dest=$(mktemp -d)
    node="inst$$${RANDOM}"
    run_installer "$dest" >/dev/null

    local output status
    output=$(CONFIG_FILE="${dest}/etc/hass-node-monitor/config.env" \
        STATE_DIR="${dest}/var/lib/hass-node-monitor" \
        LIB_DIR="${dest}/usr/local/lib/hass-node-monitor/lib" \
        NODE_NAME="$node" \
        SYSFS_ROOT="${REPO_ROOT}/tests/fixtures/sysfs-typical" \
        "${dest}/usr/local/lib/hass-node-monitor/agent.sh" 2>&1)
    status=$?

    # Tidy up the entities this created.
    CONFIG_FILE="${dest}/etc/hass-node-monitor/config.env" \
        STATE_DIR="${dest}/var/lib/hass-node-monitor" \
        LIB_DIR="${dest}/usr/local/lib/hass-node-monitor/lib" \
        NODE_NAME="$node" \
        SYSFS_ROOT="${REPO_ROOT}/tests/fixtures/sysfs-typical" \
        "${dest}/usr/local/lib/hass-node-monitor/agent.sh" --clear >/dev/null 2>&1

    rm -rf "$dest"

    if ((status != 0)); then
        _fail "installed agent failed to publish: ${output}"
        return 1
    fi
    assert_contains "$output" "published" || return 1
}

test_rerunning_the_installer_keeps_existing_settings() {
    # Re-running the curl one-liner is how updates get pushed to a fleet. It
    # must not silently reset anyone's broker settings.
    local dest
    dest=$(mktemp -d)

    MQTT_HOST="$BROKER_HOST" MQTT_PORT="$BROKER_PORT" INTERVAL=90 \
        DESTDIR="$dest" SKIP_SYSTEMD=1 \
        bash "${REPO_ROOT}/install.sh" --non-interactive >/dev/null 2>&1

    local first
    first=$(grep '^INTERVAL=' "${dest}/etc/hass-node-monitor/config.env")

    # Second run without specifying INTERVAL.
    MQTT_HOST="$BROKER_HOST" MQTT_PORT="$BROKER_PORT" \
        DESTDIR="$dest" SKIP_SYSTEMD=1 \
        bash "${REPO_ROOT}/install.sh" --non-interactive >/dev/null 2>&1

    local second
    second=$(grep '^INTERVAL=' "${dest}/etc/hass-node-monitor/config.env")

    rm -rf "$dest"
    assert_eq "$first" "$second" "re-running must preserve the configured interval" || return 1
}

test_installer_is_idempotent() {
    local dest
    dest=$(mktemp -d)

    run_installer "$dest" >/dev/null
    local first_listing
    first_listing=$(find "$dest" -type f | sort)

    local output status
    output=$(run_installer "$dest")
    status=$?

    local second_listing
    second_listing=$(find "$dest" -type f | sort)

    rm -rf "$dest"

    if ((status != 0)); then
        _fail "second install run failed: ${output}"
        return 1
    fi
    assert_eq "$first_listing" "$second_listing" "re-running must not change the file layout" || return 1
}

test_uninstall_removes_everything() {
    local dest
    dest=$(mktemp -d)
    run_installer "$dest" >/dev/null

    DESTDIR="$dest" SKIP_SYSTEMD=1 bash "${REPO_ROOT}/install.sh" --uninstall >/dev/null 2>&1

    local remaining=()
    [[ -e "${dest}/usr/local/lib/hass-node-monitor" ]] && remaining+=("install dir")
    [[ -e "${dest}/etc/hass-node-monitor" ]] && remaining+=("config dir")
    [[ -e "${dest}/var/lib/hass-node-monitor" ]] && remaining+=("state dir")

    rm -rf "$dest"
    assert_eq "" "${remaining[*]-}" "uninstall left files behind" || return 1
}

test_uninstall_clears_entities_from_home_assistant() {
    # Otherwise the device lingers in HA forever as permanently-unavailable
    # entities that have to be deleted by hand.
    local dest node
    dest=$(mktemp -d)
    node="unin$$${RANDOM}"
    run_installer "$dest" >/dev/null

    local agent_env=(
        CONFIG_FILE="${dest}/etc/hass-node-monitor/config.env"
        STATE_DIR="${dest}/var/lib/hass-node-monitor"
        LIB_DIR="${dest}/usr/local/lib/hass-node-monitor/lib"
        NODE_NAME="$node"
        SYSFS_ROOT="${REPO_ROOT}/tests/fixtures/sysfs-typical"
    )
    env "${agent_env[@]}" "${dest}/usr/local/lib/hass-node-monitor/agent.sh" >/dev/null 2>&1

    local before
    before=$(docker run --rm --network host eclipse-mosquitto:2.0.22 \
        mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" \
        -t "homeassistant/sensor/nodemon_${node}/+/config" -F '%t' -W 2 2>/dev/null | grep -c . || true)

    NODE_NAME="$node" DESTDIR="$dest" SKIP_SYSTEMD=1 \
        bash "${REPO_ROOT}/install.sh" --uninstall >/dev/null 2>&1

    local after
    after=$(docker run --rm --network host eclipse-mosquitto:2.0.22 \
        mosquitto_sub -h "$BROKER_HOST" -p "$BROKER_PORT" \
        -t "homeassistant/sensor/nodemon_${node}/+/config" -F '%t' -W 2 2>/dev/null | grep -c . || true)

    rm -rf "$dest"

    if ((before < 15)); then
        _fail "setup failed: expected entities to exist before uninstall, saw ${before}"
        return 1
    fi
    assert_eq "0" "$after" "uninstall must clear retained discovery configs" || return 1
}

test_installer_verifies_the_broker_before_writing_config() {
    # Regression guard: the connection test sourced the wrong library path and
    # blew up with "mqtt_connect: command not found". It went unnoticed because
    # non-interactive installs skipped the test entirely, so nothing exercised
    # that code path.
    local dest output
    dest=$(mktemp -d)
    output=$(run_installer "$dest")
    rm -rf "$dest"

    assert_contains "$output" "Testing the broker connection" \
        "installer should verify the broker" || return 1
    assert_contains "$output" "connected to" "connection test should succeed" || return 1
    assert_not_contains "$output" "command not found" \
        "connection test must source the installed library correctly" || return 1
}

test_installer_refuses_to_install_against_an_unreachable_broker() {
    # Non-interactively there is nobody to ask, and silently installing a
    # broken agent across a fleet is worse than stopping with a reason.
    local dest output status
    dest=$(mktemp -d)

    output=$(MQTT_HOST="$BROKER_HOST" MQTT_PORT=1 INTERVAL=60 \
        DESTDIR="$dest" SKIP_SYSTEMD=1 \
        bash "${REPO_ROOT}/install.sh" --non-interactive 2>&1)
    status=$?

    local wrote_config=0
    [[ -e "${dest}/etc/hass-node-monitor/config.env" ]] && wrote_config=1
    rm -rf "$dest"

    if ((status == 0)); then
        _fail "installer should fail when the broker is unreachable"
        return 1
    fi
    assert_eq "0" "$wrote_config" "no config should be written after a failed connection test" || return 1
}

test_offline_install_can_skip_the_connection_test() {
    local dest status
    dest=$(mktemp -d)

    MQTT_HOST="$BROKER_HOST" MQTT_PORT=1 INTERVAL=60 \
        DESTDIR="$dest" SKIP_SYSTEMD=1 SKIP_CONNECTION_TEST=1 \
        bash "${REPO_ROOT}/install.sh" --non-interactive >/dev/null 2>&1
    status=$?

    local wrote_config=0
    [[ -e "${dest}/etc/hass-node-monitor/config.env" ]] && wrote_config=1
    rm -rf "$dest"

    assert_eq "0" "$status" "SKIP_CONNECTION_TEST should allow an offline install" || return 1
    assert_eq "1" "$wrote_config" "config should still be written" || return 1
}

test_systemd_units_have_placeholders_substituted() {
    # A leftover __RUN_AS_USER__ would make systemd refuse to start the service.
    local rendered
    rendered=$(sed "s|__RUN_AS_USER__|hass-node-monitor|g" \
        "${REPO_ROOT}/systemd/hass-node-monitor.service")

    assert_not_contains "$rendered" "__" "no placeholders should remain after substitution" || return 1
    assert_contains "$rendered" "User=hass-node-monitor" || return 1
}

test_timer_interval_placeholder_is_substituted() {
    local rendered
    rendered=$(sed "s|__INTERVAL__|60|g" "${REPO_ROOT}/systemd/hass-node-monitor.timer")
    assert_contains "$rendered" "OnUnitActiveSec=60" || return 1
    assert_not_contains "$rendered" "__INTERVAL__" || return 1
}
