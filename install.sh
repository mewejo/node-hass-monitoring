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
# Settings can be preset on the command line, so rolling out to a fleet asks
# only for the password:
#
#   curl … | sudo bash -s -- --host hass.example.com --user node-health --yes
#
# Run with --help for the full list of options.
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

# True when run from a repo checkout, where the agent sources are already on
# disk next to this script and nothing needs downloading.
running_from_checkout() {
    local source_dir
    source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || return 1
    [[ -f "${source_dir}/agent.sh" && -f "${source_dir}/lib/mqtt.sh" ]]
}

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

    # Only needed to fetch the agent. Running from a clone (or from the piped
    # installer with the repo already present) downloads nothing, and demanding
    # a downloader there would block a perfectly valid install on a minimal box.
    if ! running_from_checkout; then
        command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 ||
            die "need curl or wget to download the agent"
    fi

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

# True when a setting was supplied on the command line, in which case it is
# used as given and never prompted for.
was_preset() {
    [[ " ${PRESET_KEYS[*]-} " == *" $1 "* ]]
}

# Prompt unless the setting was preset, or --yes said to take the default.
maybe_prompt() {
    local key=$1 varname=$2 label=$3 default=$4 secret=${5:-0}

    if was_preset "$key"; then
        return 0
    fi

    if ((ASSUME_YES)); then
        printf -v "$varname" '%s' "$default"
        return 0
    fi

    prompt "$varname" "$label" "$default" "$secret"
}

gather_config() {
    # With everything preset there is nothing to ask, so skip the banner too.
    if ((ASSUME_YES)) && was_preset host; then
        : "${MQTT_PORT:=1883}"
        : "${DISCOVERY_PREFIX:=homeassistant}"
        : "${INTERVAL:=60}"
        : "${RUN_AS_USER:=$DEFAULT_USER}"
        : "${MQTT_TLS:=0}"
    else
        step "MQTT connection details"
        say "  ${C_DIM}These are your MQTT broker's details, not Home Assistant's web UI.${C_OFF}"
        say "  ${C_DIM}If you use the Mosquitto add-on, the host is your Home Assistant machine.${C_OFF}"
        say ""
    fi

    maybe_prompt host MQTT_HOST "MQTT broker host" "${MQTT_HOST:-}"
    [[ -n $MQTT_HOST ]] || die "a broker host is required (pass --host)"

    maybe_prompt port MQTT_PORT "MQTT broker port" "${MQTT_PORT:-1883}"
    maybe_prompt user MQTT_USERNAME "MQTT username (blank for anonymous)" "${MQTT_USERNAME:-}"

    # The password is the one thing genuinely per-node worth typing, so it is
    # still asked for even under --yes -- unless it was preset, or there is no
    # username, or one is already stored.
    if [[ -n $MQTT_USERNAME ]]; then
        if was_preset password; then
            :
        elif [[ -n ${MQTT_PASSWORD:-} ]]; then
            if ((ASSUME_YES)); then
                : # keep the stored password
            else
                local keep
                prompt_yes_no keep "Keep the existing password" "y"
                ((keep)) || prompt MQTT_PASSWORD "MQTT password" "" 1
            fi
        elif ((TTY_AVAILABLE)); then
            prompt MQTT_PASSWORD "MQTT password for ${MQTT_USERNAME}" "" 1
        else
            die "a password is required for user '${MQTT_USERNAME}' (pass --password-stdin)"
        fi
    elif ! was_preset password; then
        MQTT_PASSWORD=""
    fi

    if ! was_preset tls; then
        if ((ASSUME_YES)); then
            MQTT_TLS="${MQTT_TLS:-0}"
        else
            prompt_yes_no MQTT_TLS "Use TLS" "${MQTT_TLS:-0}"
        fi
    fi

    maybe_prompt prefix DISCOVERY_PREFIX "Home Assistant discovery prefix" "${DISCOVERY_PREFIX:-homeassistant}"
    maybe_prompt interval INTERVAL "Reporting interval in seconds" "${INTERVAL:-60}"

    [[ $INTERVAL =~ ^[0-9]+$ ]] || die "interval must be a whole number of seconds"
    ((INTERVAL >= 10)) || die "interval must be at least 10 seconds"

    if was_preset run_as || ((ASSUME_YES)); then
        RUN_AS_USER="${RUN_AS_USER:-$DEFAULT_USER}"
        return 0
    fi

    say ""
    step "Service account"
    say "  ${C_DIM}Reading temperatures needs no privileges, so the agent runs as an${C_OFF}"
    say "  ${C_DIM}unprivileged system user by default.${C_OFF}"
    say ""

    local as_root
    prompt_yes_no as_root "Run as root instead of an unprivileged user" \
        "$([[ ${RUN_AS_USER:-} == root ]] && echo y || echo n)"
    if ((as_root)); then
        RUN_AS_USER=root
    else
        RUN_AS_USER="${RUN_AS_USER:-$DEFAULT_USER}"
        [[ $RUN_AS_USER == root ]] && RUN_AS_USER=$DEFAULT_USER
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
    if ((TTY_AVAILABLE)) && [[ ${NON_INTERACTIVE:-0} != 1 ]] && ((ASSUME_YES == 0)); then
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

    mkdir -p "${DESTDIR}${INSTALL_DIR}/lib" "${DESTDIR}${CONFIG_DIR}" "${DESTDIR}${STATE_DIR}"

    local file
    if running_from_checkout; then
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

# Persisted so re-running the installer to pick up an update keeps the
# account you chose. Without this, a deliberate root install silently reverts
# to the unprivileged user on the next run.
RUN_AS_USER=$(printf '%q' "$RUN_AS_USER")

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

    # This ran as root, so anything it created under the state directory is
    # root-owned. The service runs as an unprivileged user inside a directory
    # it owns, but it cannot rewrite a root-owned file within it -- and the
    # agent treats that write as best-effort, so the failure would be silent
    # and stale-entity cleanup would simply stop working forever.
    if [[ $RUN_AS_USER != root && $SKIP_SYSTEMD != 1 ]] && id "$RUN_AS_USER" >/dev/null 2>&1; then
        chown -R "${RUN_AS_USER}:${RUN_AS_USER}" "${DESTDIR}${STATE_DIR}"
    fi

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

usage() {
    cat <<'USAGE'
hass-node-monitor installer

  curl -fsSL https://raw.githubusercontent.com/mewejo/node-hass-monitoring/master/install.sh | sudo bash

Prompts for MQTT connection details, installs a small agent and a systemd
timer, and registers this machine with Home Assistant as an MQTT device
reporting its temperatures. Installs no packages and works on any distro.

Re-running is safe: it updates the code and leaves your settings alone.

Presets (anything given here is not prompted for):
  --host HOST            MQTT broker host
  --port PORT            MQTT broker port (default 1883)
  --user NAME            MQTT username (omit for anonymous)
  --password PASS        MQTT password. Visible in `ps` and shell history;
                         prefer --password-stdin.
  --password-stdin       read the MQTT password from standard input
  --tls / --no-tls       connect over TLS (default no)
  --prefix PREFIX        Home Assistant discovery prefix (default homeassistant)
  --interval SECONDS     reporting interval (default 60, minimum 10)
  --run-as USER          account to run the service as, or "root"
                         (default hass-node-monitor, unprivileged)
  --ignore-pattern RE    regex of sensor chip names to skip

Modes:
  --yes, -y              accept defaults for anything not preset. Still asks
                         for a password if a username needs one.
  --reconfigure          re-prompt for connection details
  --non-interactive      take settings from environment variables
  --uninstall            remove everything, including entities in HA
  --help, -h             show this

Rolling out to a fleet, asked only for the password:

  curl -fsSL .../install.sh | sudo bash -s -- \
      --host hass.example.com --user node-health --yes

Fully unattended, keeping the password out of the process list:

  printf '%s' "$PASS" | curl -fsSL .../install.sh | sudo bash -s -- \
      --host hass.example.com --user node-health --password-stdin --yes
USAGE
}

# Records which settings came from the command line. Presets are used as given
# and never prompted for, and they override anything already in config.env --
# otherwise a wrong broker could not be corrected across a fleet without
# visiting each node by hand.
PRESET_KEYS=()
ASSUME_YES=0
declare -A PRESETS=()

need_value() {
    [[ $# -ge 2 && -n ${2-} && ${2:0:2} != "--" ]] ||
        die "option $1 requires a value"
}

# Copy presets over whatever was loaded from config.env. Applied after loading
# so a preset wins, which is what makes it possible to correct a wrong broker
# across a fleet with a single re-run.
apply_presets() {
    local key
    for key in "${!PRESETS[@]}"; do
        case $key in
        host) MQTT_HOST=${PRESETS[host]} ;;
        port) MQTT_PORT=${PRESETS[port]} ;;
        user) MQTT_USERNAME=${PRESETS[user]} ;;
        password) MQTT_PASSWORD=${PRESETS[password]} ;;
        tls) MQTT_TLS=${PRESETS[tls]} ;;
        prefix) DISCOVERY_PREFIX=${PRESETS[prefix]} ;;
        interval) INTERVAL=${PRESETS[interval]} ;;
        run_as) RUN_AS_USER=${PRESETS[run_as]} ;;
        ignore_pattern) IGNORE_PATTERN=${PRESETS[ignore_pattern]} ;;
        esac
        PRESET_KEYS+=("$key")
    done
}

main() {
    local reconfigure=0 non_interactive=0


    while (($#)); do
        case "$1" in
        --host)
            need_value "$1" "${2-}"
            PRESETS[host]=$2
            shift
            ;;
        --port)
            need_value "$1" "${2-}"
            PRESETS[port]=$2
            shift
            ;;
        --user | --username)
            need_value "$1" "${2-}"
            PRESETS[user]=$2
            shift
            ;;
        --password)
            # An empty password is meaningful (anonymous), so this one accepts
            # an empty value rather than going through need_value.
            [[ $# -ge 2 ]] || die "option $1 requires a value"
            PRESETS[password]=$2
            shift
            ;;
        --password-stdin)
            # Keeps the password out of `ps` and shell history.
            IFS= read -r "PRESETS[password]" || true
            PRESET_KEYS+=(password)
            ;;
        --tls) PRESETS[tls]=1 ;;
        --no-tls) PRESETS[tls]=0 ;;
        --prefix)
            need_value "$1" "${2-}"
            PRESETS[prefix]=$2
            shift
            ;;
        --interval)
            need_value "$1" "${2-}"
            PRESETS[interval]=$2
            shift
            ;;
        --run-as)
            need_value "$1" "${2-}"
            PRESETS[run_as]=$2
            shift
            ;;
        --ignore-pattern)
            need_value "$1" "${2-}"
            PRESETS[ignore_pattern]=$2
            shift
            ;;
        --yes | -y) ASSUME_YES=1 ;;
        --uninstall) MODE=uninstall ;;
        --reconfigure) reconfigure=1 ;;
        --non-interactive) non_interactive=1 ;;
        --help | -h)
            usage
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
    apply_presets

    if ((non_interactive)); then
        config_from_environment
    elif ((had_config)) && ((reconfigure == 0)); then
        # An existing install keeps its settings, so re-running to pick up an
        # update never re-asks anything. Presets still apply on top.
        step "Existing configuration found"
        if ((${#PRESET_KEYS[@]} > 0)); then
            ok "applying presets, keeping other settings"
        else
            ok "keeping settings for ${MQTT_HOST}:${MQTT_PORT} (--reconfigure to change)"
        fi
        : "${MQTT_PORT:=1883}"
        : "${MQTT_TLS:=0}"
        : "${DISCOVERY_PREFIX:=homeassistant}"
        : "${INTERVAL:=60}"
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
