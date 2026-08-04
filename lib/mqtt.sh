#!/usr/bin/env bash
# Minimal MQTT 3.1.1 client written in pure bash.
#
# Exists because this agent has to install onto any distro without pulling in a
# package: mosquitto-clients isn't guaranteed to be present and the package name
# differs per distro anyway. We only ever need CONNECT, PUBLISH at QoS 0 and
# DISCONNECT, which are simple binary frames.
#
# Transport is bash's /dev/tcp, or an openssl s_client coproc when TLS is on.
# Sourceable with no side effects: this file only defines functions.
#
# Byte semantics matter throughout. LC_ALL=C is set so ${#s} counts bytes rather
# than characters — MQTT length prefixes are byte counts, and a single multibyte
# character would otherwise desynchronise every length in the packet.

export LC_ALL=C

# Descriptors for the broker connection. /dev/tcp gives one bidirectional fd, so
# both point at the same number; the TLS coproc gives a separate pair.
MQTT_FD_OUT=""
MQTT_FD_IN=""
MQTT_TLS_ACTIVE=0

# Set by mqtt_connect on failure, for the caller to report.
mqtt_last_error=""

# --------------------------------------------------------------------------
# Packet construction
#
# These build printf-escape strings ('\x10\x00...'), one 4-character \xNN
# escape per byte, rather than raw binary. Raw binary can't survive a bash
# variable: a NUL byte would truncate it. Escapes keep packets inspectable,
# which is also what makes them unit-testable.
# --------------------------------------------------------------------------

# Length in bytes of an escape string. Each byte is exactly one \xNN escape.
mqtt_escaped_len() {
    printf '%s' $((${#1} / 4))
}

# Encode an integer as an MQTT "remaining length" variable byte integer.
# Values up to 127 fit in a single byte; larger ones set the continuation bit
# on each group of 7 bits. Every discovery payload we send is well over 127
# bytes, so the multi-byte path is the normal case, not an edge case.
mqtt_encode_varint() {
    local value=$1 byte out=""
    while :; do
        byte=$((value % 128))
        value=$((value / 128))
        ((value > 0)) && byte=$((byte | 128))
        printf -v out '%s\\x%02x' "$out" "$byte"
        ((value > 0)) || break
    done
    printf '%s' "$out"
}

# Escape an arbitrary string so that printf '%b' reproduces it byte for byte.
# Done in-shell rather than with an external tool to stay dependency-free.
mqtt_escape() {
    local s=$1 out="" i c
    for ((i = 0; i < ${#s}; i++)); do
        c=${s:i:1}
        printf -v out '%s\\x%02x' "$out" "'$c"
    done
    printf '%s' "$out"
}

# An MQTT length-prefixed string: two big-endian length bytes, then the bytes.
#
# The two-statement form is deliberate. `local s=$1 len=${#s}` looks equivalent
# but is not: bash expands every word of a `local` before performing any of the
# assignments, so ${#s} would read whatever `s` was in an enclosing scope (or 0
# if unset) rather than the argument just passed in.
mqtt_string() {
    local s=$1
    local len=${#s}
    printf '\\x%02x\\x%02x%s' $((len / 256)) $((len % 256)) "$(mqtt_escape "$s")"
}

# Build a CONNECT packet.
# Usage: mqtt_build_connect <client_id> [username] [password]
mqtt_build_connect() {
    local client_id=$1 username=${2-} password=${3-}
    local flags=2 # clean session
    local payload

    payload=$(mqtt_string "$client_id")

    if [[ -n $username ]]; then
        flags=$((flags | 128))
        payload+=$(mqtt_string "$username")
        if [[ -n $password ]]; then
            flags=$((flags | 64))
            payload+=$(mqtt_string "$password")
        fi
    fi

    # Variable header: protocol name "MQTT", protocol level 4 (v3.1.1), connect
    # flags, then a 16-bit keepalive. Keepalive is 0 (disabled) because we
    # connect, publish and disconnect inside a second — there is nothing to keep
    # alive, and a non-zero value would just invite the broker to time us out.
    local var_header
    printf -v var_header '\\x00\\x04\\x4d\\x51\\x54\\x54\\x04\\x%02x\\x00\\x00' "$flags"

    local body="${var_header}${payload}"
    printf '\\x10%s%s' "$(mqtt_encode_varint "$(mqtt_escaped_len "$body")")" "$body"
}

# Build a PUBLISH packet at QoS 0 — no packet identifier, no acknowledgement.
# Usage: mqtt_build_publish <topic> <payload> [retain]
mqtt_build_publish() {
    local topic=$1 payload=$2 retain=${3:-0}
    local header=$((0x30))
    [[ $retain == 1 ]] && header=$((header | 1))

    local body
    body="$(mqtt_string "$topic")$(mqtt_escape "$payload")"

    printf '\\x%02x%s%s' "$header" "$(mqtt_encode_varint "$(mqtt_escaped_len "$body")")" "$body"
}

mqtt_build_disconnect() {
    printf '\\xe0\\x00'
}

# Human-readable CONNACK return codes, so a misconfigured broker produces a
# usable message rather than a silent failure on a headless node.
mqtt_connack_message() {
    case $1 in
    0) printf 'connection accepted' ;;
    1) printf 'connection refused: unacceptable protocol version' ;;
    2) printf 'connection refused: client identifier rejected' ;;
    3) printf 'connection refused: server unavailable' ;;
    4) printf 'connection refused: bad username or password' ;;
    5) printf 'connection refused: not authorised' ;;
    *) printf 'connection refused: unknown return code %s' "$1" ;;
    esac
}

# --------------------------------------------------------------------------
# Transport
# --------------------------------------------------------------------------

mqtt_open_plain() {
    local host=$1 port=$2
    local fd
    if ! exec {fd}<>"/dev/tcp/${host}/${port}"; then
        mqtt_last_error="cannot connect to ${host}:${port}"
        return 1
    fi
    MQTT_FD_OUT=$fd
    MQTT_FD_IN=$fd
    MQTT_TLS_ACTIVE=0
    return 0
}

# TLS borrows openssl as the transport. openssl is present on effectively every
# distro, and this path is only reached when TLS is explicitly enabled, so the
# default install stays genuinely dependency-free.
mqtt_open_tls() {
    local host=$1 port=$2
    if ! command -v openssl >/dev/null 2>&1; then
        mqtt_last_error="TLS requested but openssl is not installed"
        return 1
    fi

    local -a tls_opts=(-quiet -connect "${host}:${port}")
    if [[ ${MQTT_TLS_INSECURE:-0} == 1 ]]; then
        tls_opts+=(-verify 0)
    else
        tls_opts+=(-verify_return_error -verify 5)
    fi
    [[ -n ${MQTT_TLS_CAFILE:-} ]] && tls_opts+=(-CAfile "$MQTT_TLS_CAFILE")

    coproc MQTT_TLS_CO { openssl s_client "${tls_opts[@]}" 2>/dev/null; }

    # Duplicate the coproc's descriptors onto ordinary ones. Bash deliberately
    # closes coproc fds inside subshells, and we read the CONNACK from within a
    # command substitution — using the coproc fds directly fails there with
    # "Bad file descriptor". Plain duplicated fds survive into subshells.
    exec {MQTT_FD_IN}<&"${MQTT_TLS_CO[0]}"
    exec {MQTT_FD_OUT}>&"${MQTT_TLS_CO[1]}"

    MQTT_TLS_ACTIVE=1
    return 0
}

# Open a connection and complete the MQTT handshake.
# Usage: mqtt_connect <host> <port> <client_id> [username] [password] [use_tls]
mqtt_connect() {
    local host=$1 port=$2 client_id=$3 username=${4-} password=${5-} use_tls=${6:-0}
    mqtt_last_error=""

    if [[ $use_tls == 1 ]]; then
        mqtt_open_tls "$host" "$port" || return 1
    else
        mqtt_open_plain "$host" "$port" 2>/dev/null || {
            [[ -n $mqtt_last_error ]] || mqtt_last_error="cannot connect to ${host}:${port}"
            return 1
        }
    fi

    # Grouped so the stderr redirection applies to the group rather than
    # competing with the fd duplication on the same command.
    if ! { printf '%b' "$(mqtt_build_connect "$client_id" "$username" "$password")" >&"$MQTT_FD_OUT"; } 2>/dev/null; then
        mqtt_last_error="failed to send CONNECT to ${host}:${port}"
        mqtt_close
        return 1
    fi

    # Read the 4-byte CONNACK with dd rather than `read -N`: CONNACK contains
    # NUL bytes, bash variables cannot hold a NUL, and `read` would silently
    # mangle it into a wrong (often zero) return code.
    #
    # The timeout matters on a monitored node: a broker that accepts the TCP
    # connection but never replies (a half-open firewall, or a TLS port that
    # isn't MQTT) would otherwise block this read forever and wedge the timer.
    local connack
    if command -v timeout >/dev/null 2>&1; then
        connack=$(timeout "${MQTT_READ_TIMEOUT:-10}" dd bs=1 count=4 <&"$MQTT_FD_IN" 2>/dev/null | od -An -tu1)
    else
        connack=$(dd bs=1 count=4 <&"$MQTT_FD_IN" 2>/dev/null | od -An -tu1)
    fi

    local -a bytes
    read -r -a bytes <<<"$connack"

    if ((${#bytes[@]} < 4)); then
        mqtt_last_error="no CONNACK from ${host}:${port} (not an MQTT broker, or it closed the connection)"
        mqtt_close
        return 1
    fi

    if ((bytes[0] != 32)); then
        mqtt_last_error="unexpected response from ${host}:${port} (not an MQTT broker?)"
        mqtt_close
        return 1
    fi

    if ((bytes[3] != 0)); then
        mqtt_last_error="$(mqtt_connack_message "${bytes[3]}")"
        mqtt_close
        return 1
    fi

    return 0
}

# Publish one message. Requires a prior successful mqtt_connect.
mqtt_publish() {
    local topic=$1 payload=$2 retain=${3:-0}
    printf '%b' "$(mqtt_build_publish "$topic" "$payload" "$retain")" >&"$MQTT_FD_OUT"
}

# Send DISCONNECT and tear the connection down.
#
# The brief sleep is load-bearing: QoS 0 publishes are fire-and-forget, and
# closing the socket the instant after writing can drop messages the broker has
# not yet read. DISCONNECT plus a moment's grace lets the buffer drain.
mqtt_disconnect() {
    { printf '%b' "$(mqtt_build_disconnect)" >&"$MQTT_FD_OUT"; } 2>/dev/null || true
    sleep 0.1
    mqtt_close
}

mqtt_close() {
    # The braces are load-bearing. A bare `exec` with only redirections applies
    # them permanently to the current shell, so `exec {fd}>&- 2>/dev/null` would
    # not merely silence a failed close -- it would send the whole script's
    # stderr to /dev/null from here on. That silently swallowed every log line
    # and every subsequent error message on a successful publish. Wrapping in a
    # group scopes the stderr redirection to the group instead.
    if [[ -n $MQTT_FD_OUT ]]; then
        { exec {MQTT_FD_OUT}>&-; } 2>/dev/null
    fi

    if [[ $MQTT_TLS_ACTIVE == 1 ]]; then
        if [[ -n $MQTT_FD_IN ]]; then
            { exec {MQTT_FD_IN}<&-; } 2>/dev/null
        fi
        [[ -n ${MQTT_TLS_CO_PID:-} ]] && kill "$MQTT_TLS_CO_PID" 2>/dev/null
        MQTT_TLS_ACTIVE=0
    fi

    MQTT_FD_OUT=""
    MQTT_FD_IN=""
    return 0
}
