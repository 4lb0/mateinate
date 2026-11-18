# mateinate

**Keep your Mac awake only while it still has Wi-Fi and battery.**
*caffeinate, but for mate drinkers.*

`mateinate` holds sleep prevention while the Wi-Fi interface has an IP **and**
the battery is above a floor (or the charger is connected). When the network
drops — and no other network takes over — or the battery reaches the floor, it
lets the Mac sleep again.

## The problem

- `caffeinate` keeps the Mac awake, but the moment you close the lid it sleeps.
- `sudo pmset -a disablesleep 1` survives the closed lid, but it is a system
  setting that stays on: forget about it and you wake up with a dead battery.

`mateinate` flips that setting based on two facts you can check: network and
battery. It also cleans up after itself if the watcher dies.

## How it decides

| Wi-Fi with IP | Battery             | Result                          |
| ------------- | ------------------- | ------------------------------- |
| yes           | > 15% (or on AC)    | hold sleep prevention           |
| no            | any                 | wait 90s, then allow sleep      |
| yes           | <= 15% (on battery) | wait 90s, then allow sleep      |

The 90-second grace period is what makes "the network dropped but it will join
another one" work: switching Wi-Fis, or plugging the charger back in, does not
drop the hold. Both the grace and the floor are configurable.

## Install

### Homebrew

```sh
brew tap 4lb0/mateinate https://github.com/4lb0/mateinate
brew trust 4lb0/mateinate   # Homebrew only trusts its own taps by default
brew install mateinate
mateinate install          # installs the LaunchAgents, asks for the sudo rule once
mateinate status
```

### Manual

```sh
git clone https://github.com/4lb0/mateinate
cd mateinate
./install.sh               # links ~/.local/bin/mateinate and runs `mateinate install`
```

`mateinate install` adds two LaunchAgents (`com.mateinate.agent` and its
watchdog) that start at login. The first run asks for your password once to
write `/etc/sudoers.d/mateinate`, which allows exactly two commands:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

You can run that step separately with `mateinate allow-pmset`. Never run
`mateinate` with `sudo`: the agents belong to your user, only the `pmset` call
needs root.

## Usage

```sh
mateinate status      # network, battery, decision, lock, sudo readiness, agent
mateinate log 80      # tail the log
mateinate stop        # stop watching and release the lock
mateinate start       # resume
mateinate restart
mateinate config      # create/print ~/.config/mateinate/config
mateinate uninstall   # remove both agents and release the lock
```

## Safety

Because `disablesleep` is a persistent system setting, the script is defensive:

- **restore on stop**: `stop`, logout and `SIGTERM` put the previous value back
  (0, unless you had it enabled yourself);
- **stale-lock cleanup**: on every check, if it should not be holding, it clears
  a leftover `disablesleep 1`;
- **watchdog**: a second agent runs every 2 minutes and drops the lock when the
  daemon is gone or its heartbeat is stale (killed, crashed, hung);
- **`status` warns** when the lock is on but nobody is watching.

## Configuration

`~/.config/mateinate/config` is a plain shell file:

```sh
WIFI_IFACE="en0"     # Wi-Fi interface (en1 on some Intel Macs)
BATTERY_MIN=15       # floor, applied on battery only
GRACE=90             # seconds before releasing
POLL=20              # seconds between checks
MODE="pmset"         # or "caffeinate"
```

`MODE="caffeinate"` is the root-free fallback: it only prevents idle sleep and
does **not** survive the lid, so it does not solve the original problem.

Log: `~/Library/Logs/mateinate.log`.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Bootstrap failed: 125 ... Domain does not support specified action` | you ran it with `sudo`; run it as your user |
| `pmset : NOT ready` in `status` | `mateinate allow-pmset` |
| `hold: none` while the rule says HOLD | the sudo rule is missing; the log says `needs passwordless sudo` |
| lock still on after a crash | the watchdog clears it within 2 minutes; `mateinate stop` clears it now |
| `decision: allow sleep` but you are on Wi-Fi | the interface name is wrong: set `WIFI_IFACE` |

## Notes

- "Connected" means the Wi-Fi interface is `active` and has an IPv4 address.
  macOS hides the SSID from scripts without Location permission, so the network
  name is not shown anywhere.
- The battery floor only applies on battery: with the charger connected the Mac
  is charging, so the hold stays on.
- With the lid closed the display stays off but the system keeps running; that
  is the point of `disablesleep`.
- Undo everything by hand: `sudo pmset -a disablesleep 0` and
  `launchctl bootout gui/$UID/com.mateinate.agent`.

## Development

The test suite runs everything against fake `pmset`/`ifconfig`/`sudo`/
`launchctl`/`caffeinate` binaries, so it never touches real power management:

```sh
./tests/run.sh
shellcheck -s bash mateinate tests/run.sh install.sh
```

CI runs the same tests on Linux and macOS.

## License

MIT
