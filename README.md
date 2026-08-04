# node-hass-monitoring

Report a Linux machine's temperatures to Home Assistant over MQTT, with one
command and no dependencies to install.

Built for a fleet of home nodes — Proxmox hosts, a NAS, a couple of mini PCs —
where you want every machine's temperatures in Home Assistant without setting up
an agent stack on each one.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/mewejo/node-hass-monitoring/master/install.sh | sudo bash
```

It asks for your MQTT broker details, tests the connection before writing
anything, and installs a systemd timer. The machine appears in Home Assistant
under **Settings → Devices & Services → MQTT**, named after its hostname, with
one sensor per temperature the kernel exposes.

To update every node later, run the same command again: it refreshes the code
and leaves your settings alone.

### Rolling out to several nodes

Across a fleet the broker and username are the same everywhere and only the
password is worth typing, so those can be preset:

```sh
curl -fsSL https://raw.githubusercontent.com/mewejo/node-hass-monitoring/master/install.sh \
  | sudo bash -s -- --host hass.example.com --user node-health --yes
```

That asks for the password and nothing else. Anything given on the command line
is never prompted for, and `--yes` accepts defaults for the rest.

Fully unattended, keeping the password out of `ps` and your shell history:

```sh
printf '%s' "$MQTT_PASS" | curl -fsSL .../install.sh \
  | sudo bash -s -- --host hass.example.com --user node-health --password-stdin --yes
```

| Preset | Meaning |
| --- | --- |
| `--host` / `--port` | broker address |
| `--user` / `--password` | broker credentials (prefer `--password-stdin`) |
| `--tls` / `--no-tls` | connect over TLS |
| `--prefix` | Home Assistant discovery prefix |
| `--interval` | seconds between reports |
| `--run-as` | service account, or `root` |
| `--ignore-pattern` | regex of sensor chips to skip |

Presets override what is already stored, so a wrong broker can be corrected
across every node with one re-run, without touching anything else:

```sh
curl -fsSL .../install.sh | sudo bash -s -- --host newhost.example.com
```

Run `install.sh --help` for the full list.

## Why it has no dependencies

Nodes run whatever they run — Proxmox, Debian, Ubuntu, Arch — and the usual
approach of shelling out to `mosquitto_pub` means installing a package that
isn't present by default and is named differently on each distro.

So the agent speaks MQTT 3.1.1 directly over bash's `/dev/tcp`. It needs bash,
coreutils and systemd, which any of those systems already has. Nothing is
installed on the node, and there is no package manager logic to go wrong.

TLS is the one exception: enabling it uses `openssl` as the transport. openssl
is present essentially everywhere, and the default path never touches it.

## What gets reported

Every temperature under `/sys/class/hwmon` — CPU package and per-core, NVMe
drives, GPU, motherboard sensors — falling back to `/sys/class/thermal` on
machines with no hwmon temperatures, which is common on ARM boards and in VMs.

Real hardware is messier than that sounds, so some of this is deliberate:

- **Two drives, same chip name.** Two NVMe drives both report chip name `nvme`
  with a sensor labelled `Composite`. Sensors are identified by their underlying
  device path, so the drives stay distinct.
- **Stable across reboots.** `hwmon0`, `hwmon1` and so on are enumeration order
  and can shuffle. Entity IDs derive from the device path instead, so a reboot
  does not rename every sensor and orphan its history in Home Assistant.
- **Junk readings are dropped.** Unconnected motherboard pins report things like
  −128 °C, and idle GPU memory sensors report exactly 0. Neither is a
  temperature.
- **Peripherals are ignored.** A wireless mouse shows up in hwmon as
  `hidpp_battery_0`. It is not a node temperature.

A reading of about −1 °C is *not* filtered, even though it is often an
unconnected pin, because it is indistinguishable from a genuine sub-zero reading
and nodes in garages and outbuildings do drop below freezing. Prune noisy chips
with `IGNORE_PATTERN` below.

## Configuration

Settings live in `/etc/hass-node-monitor/config.env` (mode 0640 — it holds your
broker password). Edit and restart, or re-run the installer with
`--reconfigure`.

| Setting | Default | Notes |
| --- | --- | --- |
| `MQTT_HOST` | — | Broker address. With the Mosquitto add-on, your HA machine. |
| `MQTT_PORT` | `1883` | `8883` for TLS. |
| `MQTT_USERNAME` / `MQTT_PASSWORD` | empty | Blank for an anonymous broker. |
| `MQTT_TLS` | `0` | `1` to connect over TLS. |
| `DISCOVERY_PREFIX` | `homeassistant` | Only change if you changed it in HA. |
| `INTERVAL` | `60` | Seconds between reports. |
| `IGNORE_PATTERN` | batteries | Regex of chip names to skip entirely. |
| `SENSORS_MIN_CELSIUS` / `SENSORS_MAX_CELSIUS` | `-50` / `150` | Readings outside this range are treated as junk. |

To hide a noisy chip, add it to the pattern — for example, motherboard `AUXTIN`
pins with nothing attached:

```sh
IGNORE_PATTERN='hidpp_battery|_battery$|^BAT[0-9]|nct6797'
```

## Usage

```sh
systemctl status hass-node-monitor.timer     # is it running
journalctl -u hass-node-monitor.service -f   # what is it doing
systemctl start hass-node-monitor.service    # report right now

# Preview what would be published, without connecting to anything
sudo DRY_RUN=1 /usr/local/lib/hass-node-monitor/agent.sh
```

`DRY_RUN=1` is the first thing to reach for: it prints the sensors found and the
exact payloads, so you can see whether a missing sensor is a collection problem
or a Home Assistant one.

### Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/mewejo/node-hass-monitoring/master/install.sh | sudo bash -s -- --uninstall
```

This clears the retained discovery topics first, so the device disappears from
Home Assistant cleanly rather than lingering as unavailable entities.

## How it appears in Home Assistant

Each node is one device. Discovery configs are published retained, one per
sensor, and all readings go in a single JSON message per cycle — so a node with
23 sensors sends one message a minute, not 23.

Availability uses `expire_after` (three intervals) rather than a last-will
message. A will only fires on an *ungraceful* disconnect, and the agent connects
and disconnects cleanly each cycle, so a will-based availability topic would
never publish `offline` at all. With `expire_after`, a node that stops reporting
goes unavailable on its own.

If hardware changes — a GPU removed, a drive swapped — the entities that
disappear have their retained configs cleared automatically, so they don't
linger in HA as permanently-unavailable ghosts.

## Security notes

- The service runs as an unprivileged `hass-node-monitor` user by default;
  reading temperatures needs no privileges. Root is offered at install time if
  you prefer.
- The systemd unit is sandboxed (`ProtectSystem=strict`, `PrivateDevices`, no
  capabilities, network restricted to IPv4/IPv6).
- The broker password is never passed as a command-line argument, so it does not
  appear in `ps` — one of the reasons the agent doesn't shell out to an external
  MQTT client even where one exists.
- This repo is public. Nothing environment-specific is committed; your broker
  details are prompted at install time and stay on the node.

## Development

```sh
./scripts/dev-broker.sh up     # real mosquitto in docker
./tests/run.sh all             # unit + integration
./scripts/dev-broker.sh down
```

`./tests/run.sh unit` needs no broker and runs anywhere.

Tests are split deliberately. Unit tests check MQTT frame encoding against the
byte vectors published in the MQTT 3.1.1 specification rather than against
output captured from this code, so a bug cannot confirm itself. Integration
tests then run against genuine `eclipse-mosquitto` and verify with genuine
`mosquitto_sub`, proving interoperability rather than self-consistency.

CI additionally runs the unit suite on Debian, Ubuntu and Arch containers, and
asserts the zero-dependency claim by collecting sensors and building MQTT
packets on an image with no MQTT client, no Python and no curl.

Systemd is covered end to end on a runner VM, which has real systemd as PID 1:
the installer runs for real as root, and the job then waits for the timer to
fire on its own and checks that the service runs as the unprivileged user, that
readings keep arriving, that the state directory is writable under
`ProtectSystem=strict`, and that uninstall clears both the units and the
retained entities.

That last point is the one worth having: the service sets `ProtectHome=true`, so
it genuinely cannot read `/home`. Sandboxing like that looks harmless right up
until it silently breaks the thing it protects.

## Adding other metrics

Only temperatures are reported today. The collector emits
`key<TAB>name<TAB>value` records and everything downstream is generic over that,
so adding CPU load, memory or disk usage means writing another collector in
`lib/sensors.sh` rather than touching the MQTT or discovery code.

## Licence

MIT — see [LICENSE](LICENSE).
