#!/usr/bin/env bash
# Tests for preset command-line options.
#
# Rolling this out across a fleet means the broker host, username and interval
# are the same everywhere and only the password is worth typing. Presets let
# those be baked into the command, so a node install is one paste with at most
# one answer.
#
# Requires: scripts/dev-broker.sh up

BROKER_HOST=127.0.0.1
BROKER_PORT=1883

# Runs the installer with presets, non-interactively, into a sandbox.
preset_install() {
    local dest=$1
    shift
    DESTDIR="$dest" SKIP_SYSTEMD=1 bash "${REPO_ROOT}/install.sh" "$@" 2>&1
}

config_value() {
    local dest=$1 key=$2
    # Values are stored shell-quoted, so read them the way the agent does.
    (
        # shellcheck disable=SC1090
        source "${dest}/etc/hass-node-monitor/config.env"
        printf '%s' "${!key}"
    )
}

test_host_and_user_can_be_preset() {
    local dest
    dest=$(mktemp -d)
    preset_install "$dest" --host "$BROKER_HOST" --user node-health --password "" --yes >/dev/null

    local host user
    host=$(config_value "$dest" MQTT_HOST)
    user=$(config_value "$dest" MQTT_USERNAME)
    rm -rf "$dest"

    assert_eq "$BROKER_HOST" "$host" || return 1
    assert_eq "node-health" "$user" || return 1
}

test_all_settings_can_be_preset() {
    local dest
    dest=$(mktemp -d)
    preset_install "$dest" \
        --host "$BROKER_HOST" --port "$BROKER_PORT" \
        --user node-health --password "" \
        --prefix myha --interval 30 --yes >/dev/null

    local port prefix interval
    port=$(config_value "$dest" MQTT_PORT)
    prefix=$(config_value "$dest" DISCOVERY_PREFIX)
    interval=$(config_value "$dest" INTERVAL)
    rm -rf "$dest"

    assert_eq "$BROKER_PORT" "$port" || return 1
    assert_eq "myha" "$prefix" || return 1
    assert_eq "30" "$interval" || return 1
}

test_presets_override_existing_config() {
    # Otherwise you could not correct a wrong broker across a fleet without
    # visiting every node and answering prompts.
    local dest
    dest=$(mktemp -d)
    preset_install "$dest" --host "$BROKER_HOST" --interval 30 --password "" --yes >/dev/null
    preset_install "$dest" --host "$BROKER_HOST" --interval 90 --password "" --yes >/dev/null

    local interval
    interval=$(config_value "$dest" INTERVAL)
    rm -rf "$dest"
    assert_eq "90" "$interval" "a preset must override the stored value" || return 1
}

test_unspecified_settings_keep_their_stored_value() {
    # A preset for one setting must not quietly reset the others.
    local dest
    dest=$(mktemp -d)
    preset_install "$dest" --host "$BROKER_HOST" --interval 45 --prefix custom --password "" --yes >/dev/null
    preset_install "$dest" --host "$BROKER_HOST" --interval 90 --password "" --yes >/dev/null

    local prefix
    prefix=$(config_value "$dest" DISCOVERY_PREFIX)
    rm -rf "$dest"
    assert_eq "custom" "$prefix" "unrelated settings must survive" || return 1
}

test_password_can_be_read_from_stdin() {
    # Keeps the password out of the process list and the shell history, which
    # --password cannot do.
    local dest
    dest=$(mktemp -d)
    printf 'sekrit\n' | preset_install "$dest" \
        --host "$BROKER_HOST" --user node-health --password-stdin --yes >/dev/null

    local password
    password=$(config_value "$dest" MQTT_PASSWORD)
    rm -rf "$dest"
    assert_eq "sekrit" "$password" || return 1
}

test_run_as_user_can_be_preset() {
    local dest
    dest=$(mktemp -d)
    preset_install "$dest" --host "$BROKER_HOST" --run-as root --password "" --yes >/dev/null

    local run_as
    run_as=$(config_value "$dest" RUN_AS_USER)
    rm -rf "$dest"
    assert_eq "root" "$run_as" || return 1
}

test_ignore_pattern_can_be_preset() {
    # Fleets often share a noisy chip worth pruning everywhere.
    local dest
    dest=$(mktemp -d)
    preset_install "$dest" --host "$BROKER_HOST" --password "" \
        --ignore-pattern 'nct6797|hidpp' --yes >/dev/null

    local pattern
    pattern=$(config_value "$dest" IGNORE_PATTERN)
    rm -rf "$dest"
    assert_eq 'nct6797|hidpp' "$pattern" || return 1
}

test_yes_accepts_defaults_without_prompting() {
    # With --yes and a host, an install must complete with no terminal at all.
    local dest status
    dest=$(mktemp -d)
    setsid bash -c "DESTDIR='$dest' SKIP_SYSTEMD=1 bash '${REPO_ROOT}/install.sh' \
        --host '$BROKER_HOST' --yes" </dev/null >/dev/null 2>&1
    status=$?

    local has_config=0
    [[ -e "${dest}/etc/hass-node-monitor/config.env" ]] && has_config=1
    rm -rf "$dest"

    assert_eq "0" "$status" "--yes should complete with no tty" || return 1
    assert_eq "1" "$has_config" || return 1
}

test_unknown_option_is_rejected() {
    # A typo in a fleet rollout should stop, not install something unintended.
    local dest output status
    dest=$(mktemp -d)
    output=$(preset_install "$dest" --host "$BROKER_HOST" --hostname wrong --yes)
    status=$?
    rm -rf "$dest"

    if ((status == 0)); then
        _fail "an unknown option should be rejected"
        return 1
    fi
    assert_contains "$output" "unknown option" || return 1
}

test_option_requiring_a_value_rejects_a_missing_one() {
    # `--host --yes` would otherwise silently take "--yes" as the hostname.
    local dest output status
    dest=$(mktemp -d)
    output=$(preset_install "$dest" --host --yes)
    status=$?
    rm -rf "$dest"

    if ((status == 0)); then
        _fail "a flag consumed as a value should be rejected"
        return 1
    fi
    assert_contains "$output" "requires a value" || return 1
}

test_presets_still_verify_the_broker() {
    # Presets must not become a way to skip the connection check.
    local dest output status
    dest=$(mktemp -d)
    output=$(preset_install "$dest" --host "$BROKER_HOST" --port 1 --password "" --yes)
    status=$?

    local has_config=0
    [[ -e "${dest}/etc/hass-node-monitor/config.env" ]] && has_config=1
    rm -rf "$dest"

    if ((status == 0)); then
        _fail "should fail against an unreachable broker"
        return 1
    fi
    assert_eq "0" "$has_config" "no config should be written" || return 1
}

test_help_documents_the_presets() {
    local output
    output=$(bash "${REPO_ROOT}/install.sh" --help 2>&1)
    assert_contains "$output" "--host" || return 1
    assert_contains "$output" "--user" || return 1
    assert_contains "$output" "--password-stdin" || return 1
    assert_contains "$output" "--yes" || return 1
}
