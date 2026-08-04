#!/usr/bin/env bash
# Local MQTT broker for development and CI.
#
# Uses the same tests/broker/mosquitto.conf in both places, so a local test pass
# means a CI pass. Nothing here ships to monitored nodes — this is dev tooling.
#
# Usage: scripts/dev-broker.sh {up|down|logs|sub|status}
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BROKER_DIR="${REPO_ROOT}/tests/broker"
CERT_DIR="${BROKER_DIR}/certs"
CONTAINER=hass-node-monitor-broker
IMAGE=eclipse-mosquitto:2.0.22

# Credentials for the authenticated test listener. These are dummy values for a
# throwaway local/CI broker and are intentionally public; they grant access to
# nothing but this container.
TEST_USER=testuser
TEST_PASS=testpass

docker_cmd() {
    if docker info >/dev/null 2>&1; then
        docker "$@"
    else
        sudo docker "$@"
    fi
}

# Self-signed CA and server cert for the TLS listener. Generated locally rather
# than committed: checking a private key into a public repo is a bad habit even
# when the key is worthless.
generate_certs() {
    [[ -f "${CERT_DIR}/server.crt" ]] && return 0

    echo "==> generating self-signed certs for the TLS listener"
    mkdir -p "$CERT_DIR"

    openssl req -new -x509 -days 3650 -nodes \
        -subj "/CN=hass-node-monitor-test-ca" \
        -keyout "${CERT_DIR}/ca.key" -out "${CERT_DIR}/ca.crt" 2>/dev/null

    openssl req -new -nodes \
        -subj "/CN=localhost" \
        -keyout "${CERT_DIR}/server.key" -out "${CERT_DIR}/server.csr" 2>/dev/null

    # SAN matters: openssl s_client verifies the hostname, and the agent
    # connects to "localhost" in tests.
    openssl x509 -req -in "${CERT_DIR}/server.csr" -days 3650 \
        -CA "${CERT_DIR}/ca.crt" -CAkey "${CERT_DIR}/ca.key" -CAcreateserial \
        -extfile <(printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n') \
        -out "${CERT_DIR}/server.crt" 2>/dev/null

    rm -f "${CERT_DIR}/server.csr"
    chmod 644 "${CERT_DIR}"/*.key "${CERT_DIR}"/*.crt
}

generate_passwd() {
    local passwd_file="${BROKER_DIR}/passwd"
    [[ -f $passwd_file ]] && return 0

    echo "==> generating broker password file"
    # mosquitto_passwd lives in the image, so we don't need it on the host.
    : >"$passwd_file"
    docker_cmd run --rm -v "${passwd_file}:/tmp/passwd" "$IMAGE" \
        mosquitto_passwd -b /tmp/passwd "$TEST_USER" "$TEST_PASS"
}

cmd_up() {
    generate_certs
    generate_passwd

    if docker_cmd ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        docker_cmd rm -f "$CONTAINER" >/dev/null
    fi

    echo "==> starting broker (1883 anon, 1884 auth, 8883 tls)"
    docker_cmd run -d --name "$CONTAINER" \
        -p 1883:1883 -p 1884:1884 -p 8883:8883 \
        -v "${BROKER_DIR}/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro" \
        -v "${BROKER_DIR}/passwd:/mosquitto/config/passwd:ro" \
        -v "${CERT_DIR}:/mosquitto/certs:ro" \
        "$IMAGE" >/dev/null

    # Wait for readiness rather than sleeping a fixed amount: a fixed sleep is
    # either slow or flaky, and on CI it is usually both.
    local i
    for i in $(seq 1 50); do
        if (exec 3<>/dev/tcp/127.0.0.1/1883) 2>/dev/null; then
            echo "==> broker ready"
            return 0
        fi
        sleep 0.2
    done

    echo "!! broker failed to start" >&2
    docker_cmd logs "$CONTAINER" >&2 || true
    return 1
}

cmd_down() {
    docker_cmd rm -f "$CONTAINER" >/dev/null 2>&1 || true
    echo "==> broker stopped"
}

cmd_logs() { docker_cmd logs -f "$CONTAINER"; }
cmd_status() { docker_cmd ps --filter "name=${CONTAINER}"; }

# Tail every topic, so you can watch the agent publish in real time.
cmd_sub() {
    docker_cmd run --rm --network host "$IMAGE" \
        mosquitto_sub -h 127.0.0.1 -p 1883 -v -t '#'
}

case "${1:-}" in
up) cmd_up ;;
down) cmd_down ;;
logs) cmd_logs ;;
sub) cmd_sub ;;
status) cmd_status ;;
*)
    echo "usage: $0 {up|down|logs|sub|status}" >&2
    exit 2
    ;;
esac
