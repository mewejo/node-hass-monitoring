#!/usr/bin/env bash
# Installer for hass-node-monitor.
#
#   curl -fsSL https://raw.githubusercontent.com/mewejo/node-hass-monitoring/master/install.sh | sudo bash
#
# Prompts for MQTT connection details, installs a small agent and a systemd
# timer, and registers this machine with Home Assistant as an MQTT device
# reporting its temperatures.
#
# Installs NO packages and assumes no particular distro. Works the same on
# Proxmox, Debian, Ubuntu and Arch, because the agent speaks MQTT directly from
# bash rather than shelling out to a client that would have to be installed and
# is named differently everywhere.
#
# Re-running is safe: it updates the code and leaves your settings alone.
#
#   --reconfigure       re-prompt for connection details
#   --uninstall         remove everything, including entities in Home Assistant
#   --non-interactive   take settings from environment variables instead
set -uo pipefail

REPO="${REPO:-mewejo/node-hass-monitoring}"
REF="${REF:-master}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${REF}}"

INSTALL_DIR=/usr/local/lib/hass-node-monitor
CONFIG_DIR=/etc/hass-node-monitor
CONFIG_FILE="${CONFIG_DIR}/config.env"
STATE_DIR=/var/lib/hass-node-monitor
SYSTEMD_DIR=/etc/systemd/system
SERVICE_NAME=hass-node-monitor
DEFAULT_USER=hass-node-monitor

# Set by the test suite to install into a sandbox without touching systemd.
DESTDIR="${DESTDIR:-}"
SKIP_SYSTEMD="${SKIP_SYSTEMD:-0}"

MODE=install

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_DIM=$'\033[2m'
    C_OFF=$'\033[0m'
else
    C_BOLD="" C_RED="" C_GREEN="" C_DIM="" C_OFF=""
fi

say() { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$C_BOLD" "$C_OFF" "$*"; }
ok() { printf '  %s✓%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die() {
    printf '\n%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Prerequisites
#
# Everything checked here ships with any systemd Linux. Nothing is installed.
# ---------------------------------------------------------------------------

check_prerequisites() {
    step "Checking prerequisites"

    # A DESTDIR install writes only inside that directory and touches neither
    # systemd nor system users, so it needs no privileges. This is how the test
    # suite exercises the real installer without root.
    if [[ -z $DESTDIR ]]; then
        [[ $EUID -eq 0 ]] || die "must run as root (try: sudo)"
    fi

    if ((BASH_VERSINFO[0] < 4)); then
        die "bash 4 or newer is required (found ${BASH_VERSION})"
    fi

    # The agent speaks MQTT over bash's /dev/tcp. Some hardened or minimal
    # builds compile that out (--disable-net-redirections), and the failure
    # would otherwise surface as a baffling "cannot connect" at the first
    # publish rather than here where it can be explained.
    #
    # Port 1 is reserved and never listening, so a working bash reports
    # "Connection refused" while a bash without support reports that the path
    # does not exist.
    local probe
    probe=$(bash -c 'exec 3<>/dev/tcp/127.0.0.1/1' 2>&1)
    if [[ $probe == *"No such file"* || $probe == *"not supported"* ]]; then
        die "this bash was built without /dev/tcp support, which the agent requires"
    fi

    local missing=()
    local cmd
    for cmd in dd od readlink uname mktemp; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) || die "missing required commands: ${missing[*]}"

    if [[ $SKIP_SYSTEMD != 1 ]]; then
        command -v systemctl >/dev/null 2>&1 || die "systemd is required"
    fi

    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 ||
        die "need curl or wget to download the agent"

    ok "bash ${BASH_VERSION%%(*} with /dev/tcp, systemd, coreutils"
}

# ---------------------------------------------------------------------------
# Prompting
#
# Reads from /dev/tty, never stdin. Under `curl … | bash` stdin *is* the script,
# so a plain `read` consumes the script itself and the installer either hangs or
# silently accepts garbage. This is the single most common way curl-pipe
# installers break.
# ---------------------------------------------------------------------------

# Detect a usable terminal by actually opening /dev/tty, not by testing it with
# -r. The device node exists and is readable by permission even in a session
# with no controlling terminal (cron, a tty-less ssh, a container), where
# opening it fails with ENXIO. Testing -r reports success there and the first
# prompt then dies with a confusing message about the missing answer rather than
# the real problem.
TTY_AVAILABLE=0
if { exec 3</dev/tty; } 2>/dev/null; then
    TTY_AVAILABLE=1
    exec 3<&-
fi

prompt() {
    local varname=$1 label=$2 default=${3:-} secret=${4:-0}
    local input=""

    if ((TTY_AVAILABLE == 0)); then
        die "no terminal available for prompting; use --non-interactive with environment variables"
    fi

    if [[ -n $default ]]; then
        printf '  %s [%s]: ' "$label" "$default" >/dev/tty
    else
        printf '  %s: ' "$label" >/dev/tty
    fi

    if ((secret)); then
        read -r -s input </dev/tty
        printf '\n' >/dev/tty
    else
        read -r input </dev/tty
    fi

    [[ -n $input ]] || input=$default
    printf -v "$varname" '%s' "$input"
}

prompt_yes_no() {
    local varname=$1 label=$2 default=${3:-n}
    local answer

    # Settings round-trip through config.env as 0/1, so a stored value arrives
    # here as a digit. Show it back as y/n -- "Use TLS (y/n) [0]" reads like a
    # third option rather than a default.
    case "$default" in
    1 | y | yes) default=y ;;
    *) default=n ;;
    esac

    prompt answer "$label (y/n)" "$default"
    case "${answer,,}" in
    y | yes) printf -v "$varname" '1' ;;
    *) printf -v "$varname" '0' ;;
    esac
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

load_existing_config() {
    [[ -r "${DESTDIR}${CONFIG_FILE}" ]] || return 1
    # shellcheck disable=SC1090
    source "${DESTDIR}${CONFIG_FILE}"
    return 0
}

gather_config() {
    step "MQTT connection details"
    say "  ${C_DIM}These are your MQTT broker's details, not Home Assistant's web UI.${C_OFF}"
    say "  ${C_DIM}If you use the Mosquitto add-on, the host is your Home Assistant machine.${C_OFF}"
    say ""

    prompt MQTT_HOST "MQTT broker host" "${MQTT_HOST:-}"
    [[ -n $MQTT_HOST ]] || die "a broker host is required"

    prompt MQTT_PORT "MQTT broker port" "${MQTT_PORT:-1883}"
    prompt MQTT_USERNAME "MQTT username (blank for anonymous)" "${MQTT_USERNAME:-}"

    if [[ -n $MQTT_USERNAME ]]; then
        # Offer to keep the stored password rather than making the user retype
        # it on every reconfigure.
        if [[ -n ${MQTT_PASSWORD:-} ]]; then
            local keep
            prompt_yes_no keep "Keep the existing password" "y"
            ((keep)) || prompt MQTT_PASSWORD "MQTT password" "" 1
        else
            prompt MQTT_PASSWORD "MQTT password" "" 1
        fi
    else
        MQTT_PASSWORD=""
    fi

    prompt_yes_no MQTT_TLS "Use TLS" "${MQTT_TLS:-0}"
    prompt DISCOVERY_PREFIX "Home Assistant discovery prefix" "${DISCOVERY_PREFIX:-homeassistant}"
    prompt INTERVAL "Reporting interval in seconds" "${INTERVAL:-60}"

    [[ $INTERVAL =~ ^[0-9]+$ ]] || die "interval must be a whole number of seconds"
    ((INTERVAL >= 10)) || die "interval must be at least 10 seconds"

    say ""
    step "Service account"
    say "  ${C_DIM}Reading temperatures needs no privileges, so the agent runs as an${C_OFF}"
    say "  ${C_DIM}unprivileged system user by default.${C_OFF}"
    say ""

    local as_root
    prompt_yes_no as_root "Run as root instead of an unprivileged user" "n"
    if ((as_root)); then
        RUN_AS_USER=root
    else
        RUN_AS_USER="${RUN_AS_USER:-$DEFAULT_USER}"
    fi
}

config_from_environment() {
    : "${MQTT_HOST:?MQTT_HOST is required in non-interactive mode}"
    : "${MQTT_PORT:=1883}"
    : "${MQTT_USERNAME:=}"
    : "${MQTT_PASSWORD:=}"
    : "${MQTT_TLS:=0}"
    : "${DISCOVERY_PREFIX:=homeassistant}"
    : "${INTERVAL:=60}"
    : "${RUN_AS_USER:=$DEFAULT_USER}"
}

# ---------------------------------------------------------------------------
# Connection test
#
# Done before anything is written. Installing a silently broken service onto a
# dozen machines and finding out later is the failure mode worth avoiding.
# ---------------------------------------------------------------------------

test_connection() {
    step "Testing the broker connection"

    # Sourcing the freshly installed library rather than the one in the source
    # tree means this tests exactly the code the agent will run.
    # shellcheck source=lib/mqtt.sh
    source "${DESTDIR}${INSTALL_DIR}/lib/mqtt.sh"

    if mqtt_connect "$MQTT_HOST" "$MQTT_PORT" "hass-node-monitor-install-test" \
        "$MQTT_USERNAME" "$MQTT_PASSWORD" "$MQTT_TLS"; then
        mqtt_disconnect
        ok "connected to ${MQTT_HOST}:${MQTT_PORT}"
        return 0
    fi

    warn "could not connect: ${mqtt_last_error}"
    say ""

    case "$mqtt_last_error" in
    *"bad username or password"* | *"not authorised"*)
        say "  Check the username and password, and that the user is allowed to publish."
        ;;
    *"cannot connect"*)
        say "  Check the host and port, and that the broker accepts connections from this"
        say "  machine. Home Assistant's Mosquitto add-on listens on port 1883."
        ;;
    esac

    # Interactively, offer to continue: the broker may simply be down right now,
    # and the timer will retry. Non-interactively there is nobody to ask, and
    # silently installing a broken agent across a fleet is the worse outcome.
    if ((TTY_AVAILABLE)) && [[ ${NON_INTERACTIVE:-0} != 1 ]]; then
        local proceed
        say ""
        prompt_yes_no proceed "Install anyway" "n"
        ((proceed)) || die "aborted"
    else
        die "broker connection failed: ${mqtt_last_error}"
    fi
}

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

fetch() {
    local url=$1 dest=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest"
    else
        wget -qO "$dest" "$url"
    fi
}

# Install from a local checkout when run from one, otherwise download. Makes
# development and CI use the same code path as a real install.
install_files() {
    step "Installing agent files"

    local source_dir
    source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    local from_checkout=0
    [[ -f "${source_dir}/agent.sh" && -f "${source_dir}/lib/mqtt.sh" ]] && from_checkout=1

    mkdir -p "${DESTDIR}${INSTALL_DIR}/lib" "${DESTDIR}${CONFIG_DIR}" "${DESTDIR}${STATE_DIR}"

    local file
    if ((from_checkout)); then
        install -m 0755 "${source_dir}/agent.sh" "${DESTDIR}${INSTALL_DIR}/agent.sh"
        for file in mqtt sensors discovery; do
            install -m 0644 "${source_dir}/lib/${file}.sh" "${DESTDIR}${INSTALL_DIR}/lib/${file}.sh"
        done
        ok "installed from local checkout"
        return 0
    fi

    local tmp
    tmp=$(mktemp -d)

    fetch "${RAW_BASE}/agent.sh" "${tmp}/agent.sh" || {
        rm -rf "$tmp"
        die "could not download agent.sh"
    }
    for file in mqtt sensors discovery; do
        fetch "${RAW_BASE}/lib/${file}.sh" "${tmp}/${file}.sh" || {
            rm -rf "$tmp"
            die "could not download lib/${file}.sh"
        }
    done

    # A captive portal or proxy error page still downloads "successfully".
    # Syntax-checking before installing stops an HTML error page becoming the
    # installed agent, which would fail on every timer firing with a message
    # pointing nowhere useful.
    for file in agent mqtt sensors discovery; do
        bash -n "${tmp}/${file}.sh" 2>/dev/null || {
            rm -rf "$tmp"
            die "downloaded ${file}.sh is not valid bash (network or repo problem)"
        }
    done

    install -m 0755 "${tmp}/agent.sh" "${DESTDIR}${INSTALL_DIR}/agent.sh"
    for file in mqtt sensors discovery; do
        install -m 0644 "${tmp}/${file}.sh" "${DESTDIR}${INSTALL_DIR}/lib/${file}.sh"
    done
    rm -rf "$tmp"
    ok "downloaded from ${REPO}@${REF}"
}

# nologin lives in different places per distro: /usr/sbin on Debian and
# Proxmox, /usr/bin on Arch. Probing beats guessing.
find_nologin() {
    local candidate
    for candidate in /usr/sbin/nologin /usr/bin/nologin /sbin/nologin; do
        [[ -x $candidate ]] && {
            printf '%s' "$candidate"
            return 0
        }
    done
    printf '/bin/false'
}

create_user() {
    [[ $RUN_AS_USER == root ]] && return 0
    [[ $SKIP_SYSTEMD == 1 ]] && return 0

    if id "$RUN_AS_USER" >/dev/null 2>&1; then
        ok "service user ${RUN_AS_USER} already exists"
        return 0
    fi

    step "Creating service user"
    local shell
    shell=$(find_nologin)

    if command -v useradd >/dev/null 2>&1; then
        useradd --system --no-create-home --shell "$shell" "$RUN_AS_USER" ||
            die "could not create user ${RUN_AS_USER}"
    else
        die "useradd not found; create user ${RUN_AS_USER} manually or install as root"
    fi
    ok "created ${RUN_AS_USER} (${shell})"
}

write_config() {
    step "Writing configuration"

    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<EOF
# hass-node-monitor configuration
# Written by install.sh. Re-run the installer with --reconfigure to change it.

MQTT_HOST=$(printf '%q' "$MQTT_HOST")
MQTT_PORT=$(printf '%q' "$MQTT_PORT")
MQTT_USERNAME=$(printf '%q' "$MQTT_USERNAME")
MQTT_PASSWORD=$(printf '%q' "$MQTT_PASSWORD")
MQTT_TLS=$(printf '%q' "$MQTT_TLS")

DISCOVERY_PREFIX=$(printf '%q' "$DISCOVERY_PREFIX")
INTERVAL=$(printf '%q' "$INTERVAL")

# Sensors whose chip name matches this regex are not reported. Use it to prune
# noisy chips, for example AUXTIN pins with nothing connected to them:
#   IGNORE_PATTERN='hidpp_battery|_battery\$|^BAT[0-9]|AUXTIN'
IGNORE_PATTERN=$(printf '%q' "${IGNORE_PATTERN:-hidpp_battery|_battery\$|^BAT[0-9]}")

# Readings outside this range are treated as unpopulated sensors, not
# temperatures.
SENSORS_MIN_CELSIUS=$(printf '%q' "${SENSORS_MIN_CELSIUS:--50}")
SENSORS_MAX_CELSIUS=$(printf '%q' "${SENSORS_MAX_CELSIUS:-150}")
EOF

    install -m 0640 "$tmp" "${DESTDIR}${CONFIG_FILE}"
    rm -f "$tmp"

    # The file holds the broker password, so it must not be world-readable. The
    # service user needs to read it; nobody else does.
    if [[ $RUN_AS_USER != root && $SKIP_SYSTEMD != 1 ]] && id "$RUN_AS_USER" >/dev/null 2>&1; then
        chown "root:${RUN_AS_USER}" "${DESTDIR}${CONFIG_FILE}"
        chown -R "${RUN_AS_USER}:${RUN_AS_USER}" "${DESTDIR}${STATE_DIR}"
    fi

    ok "wrote ${CONFIG_FILE} (mode 0640)"
}

install_systemd_units() {
    [[ $SKIP_SYSTEMD == 1 ]] && return 0
    step "Installing systemd units"

    local source_dir tmp_service tmp_timer
    source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    tmp_service=$(mktemp)
    tmp_timer=$(mktemp)

    if [[ -f "${source_dir}/systemd/${SERVICE_NAME}.service" ]]; then
        cp "${source_dir}/systemd/${SERVICE_NAME}.service" "$tmp_service"
        cp "${source_dir}/systemd/${SERVICE_NAME}.timer" "$tmp_timer"
    else
        fetch "${RAW_BASE}/systemd/${SERVICE_NAME}.service" "$tmp_service" ||
            die "could not download the service unit"
        fetch "${RAW_BASE}/systemd/${SERVICE_NAME}.timer" "$tmp_timer" ||
            die "could not download the timer unit"
    fi

    sed -i "s|__RUN_AS_USER__|${RUN_AS_USER}|g" "$tmp_service"
    sed -i "s|__INTERVAL__|${INTERVAL}|g" "$tmp_timer"

    # Running as root means there is no separate group to drop to, and
    # Group=root is redundant noise in the unit.
    if [[ $RUN_AS_USER == root ]]; then
        sed -i '/^Group=/d' "$tmp_service"
    fi

    install -m 0644 "$tmp_service" "${DESTDIR}${SYSTEMD_DIR}/${SERVICE_NAME}.service"
    install -m 0644 "$tmp_timer" "${DESTDIR}${SYSTEMD_DIR}/${SERVICE_NAME}.timer"
    rm -f "$tmp_service" "$tmp_timer"

    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}.timer" >/dev/null 2>&1 ||
        die "could not enable ${SERVICE_NAME}.timer"

    ok "timer enabled, reporting every ${INTERVAL}s"
}

# Run once synchronously so the operator sees the discovered sensors and can
# confirm the device reached Home Assistant before walking away from the box.
first_run() {
    [[ $SKIP_SYSTEMD == 1 ]] && return 0
    step "Publishing an initial reading"

    local output status
    output=$(CONFIG_FILE="${DESTDIR}${CONFIG_FILE}" STATE_DIR="${DESTDIR}${STATE_DIR}" \
        LIB_DIR="${DESTDIR}${INSTALL_DIR}/lib" \
        "${DESTDIR}${INSTALL_DIR}/agent.sh" 2>&1)
    status=$?

    if ((status == 0)); then
        ok "${output}"
    else
        warn "first run failed: ${output}"
        say ""
        say "  The timer is installed and will retry. Investigate with:"
        say "    systemctl status ${SERVICE_NAME}.service"
        say "    journalctl -u ${SERVICE_NAME}.service -n 50"
        return 1
    fi
}

show_summary() {
    local node
    node=$(uname -n)
    node=${node%%.*}

    say ""
    say "${C_GREEN}${C_BOLD}Done.${C_OFF} ${node} is reporting to Home Assistant."
    say ""
    say "  Look for a device named ${C_BOLD}${node}${C_OFF} under"
    say "  Settings -> Devices & Services -> MQTT."
    say ""
    say "  ${C_DIM}status:${C_OFF}    systemctl status ${SERVICE_NAME}.timer"
    say "  ${C_DIM}logs:${C_OFF}      journalctl -u ${SERVICE_NAME}.service -f"
    say "  ${C_DIM}run now:${C_OFF}   systemctl start ${SERVICE_NAME}.service"
    say "  ${C_DIM}settings:${C_OFF}  ${CONFIG_FILE}"
    say ""
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

cmd_uninstall() {
    if [[ -z $DESTDIR ]]; then
        [[ $EUID -eq 0 ]] || die "must run as root (try: sudo)"
    fi

    step "Removing hass-node-monitor"

    # Clear the retained discovery configs first, while the config and agent are
    # still present. Skipping this leaves the device in Home Assistant forever
    # as a set of permanently-unavailable entities that must be deleted by hand.
    if [[ -x "${DESTDIR}${INSTALL_DIR}/agent.sh" && -r "${DESTDIR}${CONFIG_FILE}" ]]; then
        if CONFIG_FILE="${DESTDIR}${CONFIG_FILE}" STATE_DIR="${DESTDIR}${STATE_DIR}" \
            LIB_DIR="${DESTDIR}${INSTALL_DIR}/lib" \
            "${DESTDIR}${INSTALL_DIR}/agent.sh" --clear 2>/dev/null; then
            ok "removed entities from Home Assistant"
        else
            warn "could not reach the broker; entities may need deleting in HA by hand"
        fi
    fi

    if [[ $SKIP_SYSTEMD != 1 ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now "${SERVICE_NAME}.timer" >/dev/null 2>&1 || true
        systemctl disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
        rm -f "${DESTDIR}${SYSTEMD_DIR}/${SERVICE_NAME}.service" \
            "${DESTDIR}${SYSTEMD_DIR}/${SERVICE_NAME}.timer"
        systemctl daemon-reload
        ok "removed systemd units"
    fi

    rm -rf "${DESTDIR}${INSTALL_DIR}" "${DESTDIR}${STATE_DIR}"
    ok "removed agent and state"

    # The config holds the broker password, so it goes too.
    rm -rf "${DESTDIR}${CONFIG_DIR}"
    ok "removed configuration"

    if id "$DEFAULT_USER" >/dev/null 2>&1 && [[ $SKIP_SYSTEMD != 1 ]]; then
        userdel "$DEFAULT_USER" >/dev/null 2>&1 && ok "removed service user"
    fi

    say ""
    say "${C_GREEN}Uninstalled.${C_OFF}"
}

# ---------------------------------------------------------------------------

main() {
    local reconfigure=0 non_interactive=0

    while (($#)); do
        case "$1" in
        --uninstall) MODE=uninstall ;;
        --reconfigure) reconfigure=1 ;;
        --non-interactive) non_interactive=1 ;;
        --help | -h)
            sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown option: $1" ;;
        esac
        shift
    done

    if [[ $MODE == uninstall ]]; then
        cmd_uninstall
        return
    fi

    say ""
    say "${C_BOLD}hass-node-monitor${C_OFF} — report node temperatures to Home Assistant"
    say ""

    check_prerequisites

    local had_config=0
    load_existing_config && had_config=1

    if ((non_interactive)); then
        config_from_environment
    elif ((had_config)) && ((reconfigure == 0)); then
        step "Existing configuration found"
        ok "keeping settings for ${MQTT_HOST}:${MQTT_PORT} (--reconfigure to change)"
        : "${RUN_AS_USER:=$DEFAULT_USER}"
    else
        gather_config
    fi

    install_files
    create_user

    # After install_files, because the connection test sources the *installed*
    # MQTT library and so exercises exactly the code the agent will run.
    #
    # Run in non-interactive mode too: a bulk install that quietly leaves a
    # broken agent on a dozen machines is worse than one that stops and says
    # why. SKIP_CONNECTION_TEST=1 escapes it for genuinely offline provisioning.
    NON_INTERACTIVE=$non_interactive
    if [[ ${SKIP_CONNECTION_TEST:-0} != 1 ]]; then
        test_connection
    fi

    write_config
    install_systemd_units
    first_run || true
    show_summary
}

main "$@"
