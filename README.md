<p align="center">
  <img src="assets/logo.svg" alt="" width="112" height="112">
</p>

<h1 align="center">node-hass-monitoring</h1>

<p align="center">
  Put your machines' temperatures in Home Assistant.<br>
  One command per node. Nothing to install.
</p>

<p align="center">
  <a href="https://github.com/mewejo/node-hass-monitoring/actions/workflows/test.yml">
    <img src="https://github.com/mewejo/node-hass-monitoring/actions/workflows/test.yml/badge.svg" alt="tests">
  </a>
</p>

---

You've got a few machines around the house — a Proxmox box, a NAS, a mini PC
under the telly — and no idea how hot any of them are running. This puts every
one of them in Home Assistant as a proper device, with a sensor for each
temperature the machine knows about, so you can graph them, alert on them, or
just satisfy yourself that the loft server isn't cooking.

Paste one command into a node and it shows up in Home Assistant about a second
later:

```
Settings → Devices & Services → MQTT

  pve01                    ← your machine, named after its hostname
    k10temp Tctl            62.8 °C
    k10temp Tccd1           58.0 °C
    nvme Composite          51.9 °C
    amdgpu edge             51.0 °C
    …
```

It works the same on Proxmox, Debian, Ubuntu and Arch, because it installs
**no packages at all** — not even an MQTT client. More on that
[below](#why-there-are-no-dependencies) if you're curious.

## Before you start

You need somewhere for the readings to go: an **MQTT broker**. If you already
have one, skip ahead. If not, Home Assistant can run one for you in about three
minutes.

> **This has nothing to do with a Home Assistant API token.** Those are for
> talking to HA's own API. This publishes to MQTT instead, and Home Assistant
> picks the devices up from there. What you need is a broker and a username.

### 1. Install the Mosquitto broker

In Home Assistant: **Settings → Add-ons → Add-on Store**, find **Mosquitto
broker**, install it, and start it. Turn on "Start on boot" while you're there.

📖 [Mosquitto add-on docs](https://github.com/home-assistant/addons/blob/master/mosquitto/DOCS.md)

### 2. Create a user for your nodes

The Mosquitto add-on checks credentials against Home Assistant's own user
accounts, so make one just for this.

**Settings → People → Users → Add User**. Call it something like
`node-health`, give it a strong password, and leave it as a normal
(non-administrator) user.

Two things worth getting right:

- **Don't enable multi-factor authentication on it.** The add-on's login can't
  handle MFA, and the failure looks like a wrong password.
- **Don't reuse your own login.** If you ever change your password, every node
  stops reporting at once.

📖 [Home Assistant users and authentication](https://www.home-assistant.io/docs/authentication/)

### 3. Add the MQTT integration

Installing the broker isn't enough on its own — Home Assistant also has to be
listening to it.

**Settings → Devices & Services → Add Integration → MQTT**. If you're using the
add-on, HA usually offers to configure it for you in one click.

📖 [MQTT integration docs](https://www.home-assistant.io/integrations/mqtt/)

### 4. Note down three things

You'll be asked for these in a moment:

| | Example |
| --- | --- |
| **Broker address** | your Home Assistant machine, e.g. `homeassistant.local` |
| **Username** | `node-health` |
| **Password** | whatever you set in step 2 |

The port is `1883` unless you've changed it.

## Install

On the machine you want to monitor:

```sh
curl -fsSL https://raw.githubusercontent.com/mewejo/node-hass-monitoring/master/install.sh | sudo bash
```

It asks for your broker details, checks it can actually connect before changing
anything, and sets up a timer to report every 60 seconds. Then go and look in
**Settings → Devices & Services → MQTT** — your machine should be there, named
after its hostname.

If it can't reach the broker, it tells you why and stops rather than leaving a
broken agent behind.

### More nodes

Once you've done one, the rest are quicker. Preset the bits that are the same
everywhere and it'll only ask for the password:

```sh
curl -fsSL https://raw.githubusercontent.com/mewejo/node-hass-monitoring/master/install.sh \
  | sudo bash -s -- --host homeassistant.local --user node-health --yes
```

Or fully unattended, keeping the password out of your shell history:

```sh
printf '%s' "$MQTT_PASS" | curl -fsSL .../install.sh \
  | sudo bash -s -- --host homeassistant.local --user node-health --password-stdin --yes
```

| Preset | What it sets |
| --- | --- |
| `--host` / `--port` | where the broker is |
| `--user` / `--password` | broker credentials (prefer `--password-stdin`) |
| `--tls` / `--no-tls` | connect over TLS |
| `--prefix` | Home Assistant discovery prefix |
| `--interval` | seconds between reports |
| `--run-as` | which account runs it, or `root` |
| `--ignore-pattern` | sensors to skip |
| `--yes` | accept defaults for anything not preset |

`install.sh --help` lists the lot.

### Updating

Run the same command again. It updates the code and leaves your settings alone —
no prompts, no re-entering the password.

If something needs to change everywhere, preset it and it'll override what's
stored, leaving everything else untouched:

```sh
curl -fsSL .../install.sh | sudo bash -s -- --host new-broker.local
```

## What you'll see

A sensor for every temperature the kernel exposes: CPU package and per-core,
NVMe drives, GPU, motherboard sensors. On machines with no hwmon sensors — some
VMs and ARM boards — it falls back to thermal zones.

Some tidying happens automatically, because real hardware is messier than you'd
hope:

- **Two identical drives stay separate.** Two NVMes both call themselves `nvme`
  with a sensor called `Composite`; they're told apart by their hardware
  address, not their name.
- **Sensors keep their identity across reboots**, so your history doesn't get
  orphaned when the kernel enumerates things in a different order.
- **Nonsense readings are dropped.** Unconnected motherboard pins love to report
  −128 °C, and idle GPU memory reports exactly 0.
- **Your mouse is not a server.** Wireless peripherals show up in the same place
  as real sensors; they're filtered out.

If your motherboard exposes sensors you don't care about, prune them in the
config — see `IGNORE_PATTERN` below.

## Configuration

Settings live in `/etc/hass-node-monitor/config.env`. Edit it and restart, or
re-run the installer with `--reconfigure`.

| Setting | Default | What it does |
| --- | --- | --- |
| `MQTT_HOST` | — | broker address |
| `MQTT_PORT` | `1883` | `8883` if you're using TLS |
| `MQTT_USERNAME` / `MQTT_PASSWORD` | empty | leave blank for an anonymous broker |
| `MQTT_TLS` | `0` | `1` to connect over TLS |
| `DISCOVERY_PREFIX` | `homeassistant` | only change if you changed it in HA |
| `INTERVAL` | `60` | seconds between reports |
| `IGNORE_PATTERN` | batteries | regex of sensor chips to skip entirely |
| `SENSORS_MIN_CELSIUS` / `SENSORS_MAX_CELSIUS` | `-50` / `150` | anything outside this is treated as junk |

To silence a chatty chip — say the `AUXTIN` pins on a motherboard with nothing
plugged into them:

```sh
IGNORE_PATTERN='hidpp_battery|_battery$|^BAT[0-9]|nct6797'
```

The file contains your broker password, so it's readable only by root and the
service account.

## Day to day

```sh
systemctl status hass-node-monitor.timer     # is it running?
journalctl -u hass-node-monitor.service -f   # what's it doing?
systemctl start hass-node-monitor.service    # report right now
```

To see exactly what it would send, without connecting to anything:

```sh
sudo DRY_RUN=1 /usr/local/lib/hass-node-monitor/agent.sh
```

That's the first thing to try when something looks wrong — it tells you
straight away whether a missing sensor is a problem here or at the Home
Assistant end.

## When it doesn't work

**Nothing appeared in Home Assistant.**
Check the MQTT *integration* is added, not just the broker running (step 3
above). Without it, your nodes are publishing into the void.

**"connection refused: not authorised".**
Wrong username or password — or the account has MFA enabled, which the
Mosquitto add-on can't use.

**"cannot connect".**
Wrong address or port, or a firewall in the way. The broker listens on `1883`.

**"no usable temperature sensors found".**
Some VMs genuinely expose none. Run the `DRY_RUN` command above to see what the
machine offers.

**A device is stuck showing "unavailable".**
That's the node not reporting — check `systemctl status hass-node-monitor.timer`
on it. Sensors go unavailable on purpose after three missed intervals, rather
than showing a stale temperature forever.

**Old sensors are hanging around after a hardware change.**
They shouldn't — removed sensors get cleaned up automatically. If any are stuck,
`sudo /usr/local/lib/hass-node-monitor/agent.sh --clear` removes the lot, and
the next run re-adds what's still there.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/mewejo/node-hass-monitoring/master/install.sh | sudo bash -s -- --uninstall
```

This tidies up after itself in Home Assistant too, so the device disappears
properly instead of hanging around greyed out.

## Why there are no dependencies

The usual way to do this is to call `mosquitto_pub`, which means installing a
package that isn't there by default and is named differently on every distro.

Instead the agent speaks MQTT directly over bash's `/dev/tcp`. It needs bash,
coreutils and systemd — which your machine already has. Nothing gets installed,
and there's no package manager logic to break on the one node that's running
something unusual.

TLS is the single exception: turning it on uses `openssl`, which is on
essentially every system anyway. The default path never touches it.

A few other decisions worth knowing about:

- **The service runs unprivileged.** Reading temperatures needs no privileges,
  so it runs as its own locked-down system user with systemd sandboxing. Root is
  offered at install time if you'd rather.
- **Your password never appears in `ps`.** It's never passed as a command-line
  argument — which is one more reason not to shell out to an external client.
- **Availability is handled by `expire_after`, not a last-will message.** A will
  only fires on an *ungraceful* disconnect, and this connects and disconnects
  cleanly every cycle, so a will-based approach would never actually mark
  anything offline.
- **Readings are retained**, so entities show a value the moment they're
  discovered and repopulate immediately after a Home Assistant restart, instead
  of sitting empty until the next cycle.

## Development

```sh
./scripts/dev-broker.sh up     # real mosquitto, in docker
./tests/run.sh all             # unit + integration
./scripts/dev-broker.sh down
```

`./tests/run.sh unit` needs no broker and runs anywhere.

The tests are split on purpose. Unit tests check MQTT frame encoding against the
byte sequences published in the MQTT 3.1.1 spec, rather than against output
captured from this code — so a bug can't quietly confirm itself. Integration
tests then run against genuine `eclipse-mosquitto` and verify with genuine
`mosquitto_sub`, which proves it actually interoperates.

CI also runs the unit suite on Debian, Ubuntu and Arch, proves the
no-dependencies claim on an image stripped of any MQTT client, Python and curl,
and installs the whole thing for real on a VM to check the timer fires, the
sandboxing doesn't get in the way, and uninstalling leaves nothing behind.

## Adding other metrics

Only temperatures for now. The collector emits simple
`key<TAB>name<TAB>value` records and everything downstream is generic over that,
so adding CPU load, memory or disk usage means writing another collector in
`lib/sensors.sh` — the MQTT and Home Assistant plumbing doesn't change.

## Licence

MIT — see [LICENSE](LICENSE).
