#!/usr/bin/env bash
# Reads this machine's temperatures and publishes them to Home Assistant over
# MQTT. Run periodically by hass-node-monitor.timer; safe to run by hand.
#
#   agent.sh              publish one cycle
#   DRY_RUN=1 agent.sh    print what would be published, connect to nothing
#   agent.sh --clear      remove this node's entities from Home Assistant
#
# Needs no privileges: everything it reads under /sys is world-readable.
set -uo pipefail

AGENT_VERSION="0.1.0"

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib}"
CONFIG_FILE="${CONFIG_FILE:-/etc/hass-node-monitor/config.env}"
STATE_DIR="${STATE_DIR:-/var/lib/hass-node-monitor}"
PUBLISHED_ENTITIES_FILE="${STATE_DIR}/published-entities"

log() { printf '%s\n' "$*" >&2; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

if [[ -r $CONFIG_FILE ]]; then
    # shellcheck disable=SC1090 # path is configurable and written at install time
    source "$CONFIG_FILE"
elif [[ ${DRY_RUN:-0} != 1 ]]; then
    die "cannot read ${CONFIG_FILE} (run install.sh first)"
fi

: "${MQTT_HOST:=}"
: "${MQTT_PORT:=1883}"
: "${MQTT_USERNAME:=}"
: "${MQTT_PASSWORD:=}"
: "${MQTT_TLS:=0}"
: "${DISCOVERY_PREFIX:=homeassistant}"
: "${INTERVAL:=60}"
: "${TOPIC_PREFIX:=nodemon}"

# The hostname identifies the node, as it is what you already use to refer to
# these machines. `uname -n` rather than `hostname`: the hostname binary is not
# installed by default on Arch, and uname is coreutils and always present.
# Truncated at the first dot so a FQDN and a short name agree.
NODE_NAME=${NODE_NAME:-$(uname -n)}
NODE_NAME=${NODE_NAME%%.*}

# --------------------------------------------------------------------------
# Libraries
# --------------------------------------------------------------------------

# shellcheck source=lib/sensors.sh
source "${LIB_DIR}/sensors.sh"
# shellcheck source=lib/mqtt.sh
source "${LIB_DIR}/mqtt.sh"
# shellcheck source=lib/discovery.sh
source "${LIB_DIR}/discovery.sh"

NODE_ID=$(sensors_slugify "$NODE_NAME")
[[ -n $NODE_ID ]] || die "could not derive a node id from hostname '${NODE_NAME}'"

STATE_TOPIC="${TOPIC_PREFIX}/${NODE_ID}/state"
export NODE_ID NODE_NAME DISCOVERY_PREFIX STATE_TOPIC INTERVAL AGENT_VERSION

# --------------------------------------------------------------------------
# Entity bookkeeping
#
# Hardware and kernel drivers change: a GPU is removed, a driver renames its
# sensors, a disk is swapped. Discovery configs are retained, so without
# cleanup the entities they created linger in Home Assistant forever as
# permanently-unavailable ghosts. Recording what we published lets us clear
# exactly the ones that have gone away.
# --------------------------------------------------------------------------

read_published_entities() {
    [[ -r $PUBLISHED_ENTITIES_FILE ]] || return 0
    cat "$PUBLISHED_ENTITIES_FILE"
}

write_published_entities() {
    # Best-effort: a node that cannot write state still publishes temperatures
    # fine, it just cannot clean up entities later. Refusing to report at all
    # would be the worse trade.
    #
    # But the failure is reported rather than swallowed. A silent failure here
    # means stale-entity cleanup quietly stops working and nothing ever says
    # so -- which is exactly what happened when the installer's first run, as
    # root, left this file root-owned under a directory owned by the service
    # user.
    if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
        log "warning: cannot create ${STATE_DIR}; stale entities will not be cleaned up"
        return 0
    fi

    if ! printf '%s\n' "$@" >"$PUBLISHED_ENTITIES_FILE" 2>/dev/null; then
        log "warning: cannot write ${PUBLISHED_ENTITIES_FILE} (owned by another user?);"
        log "         stale entities will not be cleaned up"
    fi
    return 0
}

# --------------------------------------------------------------------------
# Publishing
# --------------------------------------------------------------------------

connect_or_die() {
    [[ -n $MQTT_HOST ]] || die "MQTT_HOST is not set"

    # The client ID includes the PID because MQTT requires it to be unique per
    # connection: when a second client connects with an ID already in use, the
    # broker disconnects the first one. Two overlapping runs -- a manual
    # `systemctl start` alongside a timer firing, or the installer's first
    # publish racing the timer it just enabled -- would otherwise kick each
    # other off mid-publish, losing readings while both appeared to succeed
    # (a QoS 0 publish into a socket the broker has already closed reports no
    # error). Sessions are clean and QoS is 0, so a per-run ID costs nothing.
    if ! mqtt_connect "$MQTT_HOST" "$MQTT_PORT" "nodemon-${NODE_ID}-$$" \
        "$MQTT_USERNAME" "$MQTT_PASSWORD" "$MQTT_TLS"; then
        die "MQTT: ${mqtt_last_error}"
    fi
}

# Clear every entity this node has published, so the device disappears from
# Home Assistant cleanly. Used by `--clear` and by the installer's uninstall.
cmd_clear() {
    local -a previous
    mapfile -t previous < <(read_published_entities)

    if ((${#previous[@]} == 0)); then
        log "no previously published entities recorded; nothing to clear"
        return 0
    fi

    if [[ ${DRY_RUN:-0} == 1 ]]; then
        local key
        for key in "${previous[@]}"; do
            [[ -n $key ]] && printf 'CLEAR %s\n' "$(discovery_config_topic "$key")"
        done
        return 0
    fi

    connect_or_die

    local key cleared=0
    for key in "${previous[@]}"; do
        [[ -n $key ]] || continue
        # An empty retained payload is how MQTT deletes a retained message, and
        # how Home Assistant is told to forget a discovered entity.
        mqtt_publish "$(discovery_config_topic "$key")" "" 1
        ((cleared++))
    done

    mqtt_disconnect
    rm -f "$PUBLISHED_ENTITIES_FILE" 2>/dev/null || true
    log "cleared ${cleared} entities from Home Assistant"
}

cmd_publish() {
    local records
    records=$(sensors_collect_temperatures)

    if [[ -z $records ]]; then
        log "no usable temperature sensors found on this machine"
        log "checked ${SYSFS_ROOT:-/sys}/class/hwmon and ${SYSFS_ROOT:-/sys}/class/thermal"
        return 1
    fi

    local -a current_keys=()
    local key name value
    while IFS=$'\t' read -r key name value; do
        [[ -n $key ]] && current_keys+=("$key")
    done <<<"$records"

    local state_payload
    state_payload=$(printf '%s\n' "$records" | discovery_state_payload)

    local -a previous_keys=()
    mapfile -t previous_keys < <(read_published_entities)

    # Republish discovery only when the entity set changes. Retained configs
    # persist in the broker, so resending identical ones every cycle is pure
    # noise -- on a 60 second timer that is 25 needless retained publishes a
    # minute, forever.
    local current_sorted previous_sorted discovery_needed=0
    current_sorted=$(printf '%s\n' "${current_keys[@]}" | sort)
    previous_sorted=$(printf '%s\n' "${previous_keys[@]+"${previous_keys[@]}"}" | sort)
    [[ $current_sorted != "$previous_sorted" ]] && discovery_needed=1

    # Entities that existed last run but not this one.
    local -a stale_keys=()
    if ((${#previous_keys[@]} > 0)); then
        mapfile -t stale_keys < <(comm -23 <(printf '%s\n' "$previous_sorted") <(printf '%s\n' "$current_sorted") | grep -v '^$' || true)
    fi

    if [[ ${DRY_RUN:-0} == 1 ]]; then
        printf '# node: %s (id: %s)\n' "$NODE_NAME" "$NODE_ID"
        printf '# broker: %s:%s tls=%s\n' "${MQTT_HOST:-<unset>}" "$MQTT_PORT" "$MQTT_TLS"
        printf '# sensors found: %d\n\n' "${#current_keys[@]}"

        while IFS=$'\t' read -r key name value; do
            [[ -n $key ]] || continue
            printf 'PUBLISH (retain) %s\n' "$(discovery_config_topic "$key")"
            printf '  %s\n' "$(discovery_config_payload "$key" "$name")"
        done <<<"$records"

        printf '\nPUBLISH %s\n' "$STATE_TOPIC"
        printf '  %s\n' "$state_payload"

        if ((${#stale_keys[@]} > 0)); then
            printf '\n'
            for key in "${stale_keys[@]}"; do
                printf 'CLEAR %s\n' "$(discovery_config_topic "$key")"
            done
        fi
        return 0
    fi

    connect_or_die

    if ((discovery_needed)); then
        while IFS=$'\t' read -r key name value; do
            [[ -n $key ]] || continue
            mqtt_publish "$(discovery_config_topic "$key")" "$(discovery_config_payload "$key" "$name")" 1
        done <<<"$records"
    fi

    local stale_key
    for stale_key in "${stale_keys[@]+"${stale_keys[@]}"}"; do
        [[ -n $stale_key ]] || continue
        mqtt_publish "$(discovery_config_topic "$stale_key")" "" 1
        log "removed stale entity: ${stale_key}"
    done

    mqtt_publish "$STATE_TOPIC" "$state_payload"
    mqtt_disconnect

    write_published_entities "${current_keys[@]}"

    if ((discovery_needed)); then
        log "published ${#current_keys[@]} sensors (discovery refreshed)"
    else
        log "published ${#current_keys[@]} sensors"
    fi
}

case "${1:-}" in
--clear) cmd_clear ;;
--version) printf '%s\n' "$AGENT_VERSION" ;;
"") cmd_publish ;;
*) die "unknown argument: $1 (expected --clear or --version)" ;;
esac
