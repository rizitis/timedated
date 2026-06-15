# Timedate Daemon

**TimeDate** Daemon is a system service that can be used to control the system time
and related settings.

This is a replacement for the *systemd* service that controls the **org.freedesktop.timedate1**
*D-Bus interface*, intended for GNU/Linux distributions that do not use *systemd*.

You can find the specification at: [**Freedesktop.org**](https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.timedate1.html)

## Acknowledgements

This project is a **fork** of the original
[Timedate Daemon](https://github.com/radix-linux/timedated) by
**Andrey V. Kosteltsev** (`kx@radix.pro`), originally developed for **Radix cross Linux**.

Many thanks to the original author for the solid foundation. This fork adds
fixes and improvements targeting **Slackware**, including a Bash
`timedatectl` client and several bug fixes in the daemon.

## How it works

**TimeDate** Daemon supports an interactive parameter which controls
whether *PolKit* should interactively ask the user for authentication
credentials when required. Alternatively, when the interactive method is not
applicable, user permissions can be set via *PolKit* rules in the
`/usr/share/polkit-1/rules.d/org.freedesktop.timedate1.rules` file. For example,
a system administrator can add desktop users to the **wheel** group to grant
them access to the **org.freedesktop.timedate1** *D-Bus interface*.

The privileged group is configurable at build time via the
`-Dprivileged-group=` Meson option (default: `wheel`).

## Requirements

 | Package           |      | min Version  |
 | :---              | :--: | :---         |
 | glib-2.0          |  >=  |  2.76        |
 | gobject-2.0       |  >=  |  2.76        |
 | gio-2.0           |  >=  |  2.76        |
 | polkit-gobject-1  |  >=  |  123         |
 | libpcre2-8        |  >=  |  10.36       |
 | dbus              |  >=  |  1.13.18     |

At runtime, the daemon expects an NTP daemon controllable through
`/etc/rc.d/rc.ntpd` (the Slackware **ntp** package), `hwclock`
(from **util-linux**) for RTC access, and the system timezone database in
`/usr/share/zoneinfo/` (the **tzdata** package).

## How to Build

```  
Latest release will be found: https://forge.slackware.nl/rizitis/timedated/releases
PLEASE Read README in SlackBuild folder
```

Build-time options (see `meson_options.txt`):

| Option              | Default                | Description                          |
| :---                | :---                   | :---                                 |
| `privileged-group`  | `wheel`                | Group with administrator privileges  |
| `hwclock_conf`      | `/etc/hardwareclock`   | Hardware clock config file           |
| `adjtime_conf`      | `/etc/adjtime`         | Adjtime config file                  |
| `ntpd_conf`         | `/etc/ntp.conf`        | NTP daemon config file               |
| `ntpd_rc`           | `/etc/rc.d/rc.ntpd`    | NTP daemon start/stop script         |

## Supported Distributions

 - [Slackware](http://www.slackware.com) — *Slackware-current works out of the box*

For other systems, a specific implementation of NTP daemon control may need to
be developed.

## timedatectl

A Bash implementation of `timedatectl` is included, providing a familiar
command-line interface to the daemon over D-Bus.

```
timedatectl --help
Usage: timedatectl [OPTIONS] COMMAND

Commands:
  status                   Show current time settings
  show                     Show settings in key=value format
  set-timezone ZONE        Set the system timezone (e.g. Europe/Athens)
  set-local-rtc [0|1]      Control whether RTC is in local time
  set-ntp [0|1]            Enable or disable NTP synchronization
  set-time TIME            Set time manually (e.g. '2026-05-31 20:30:00')
  list-timezones           List available timezones
  sync-now                 Force an immediate time sync (works even if NTP is off)

Options:
  -h, --help               Show this help
```

### Examples

```
timedatectl status
               Local time: Mon Jun  1 00:10:31 EEST 2026
           Universal time: Sun May 31 21:10:32 UTC 2026
                 RTC time: 2026-06-01 00:10:31.952579+03:00
                Time zone: Europe/Athens
              NTP enabled: yes
         NTP synchronized: yes
          RTC in local TZ: yes
               CanNTP: yes
```

```
timedatectl show
Timezone=Europe/Athens
LocalRTC=true
CanNTP=true
NTP=true
NTPSynchronized=true
TimeUSec=1780261839000000
RTCTimeUSec=2026-06-01T00:10:39.117263+03:00
```

```
timedatectl list-timezones | grep Athens
Europe/Athens
```

To set the time manually, NTP must be disabled first:

```
timedatectl set-ntp 0
timedatectl set-time '2026-05-31 20:30:00'
```

To recover the correct time afterwards:

```
sudo timedatectl sync-now
```

The daemon properties can also be queried directly over D-Bus:

```
busctl get-property org.freedesktop.timedate1 /org/freedesktop/timedate1 \
  org.freedesktop.timedate1 Timezone
s "Europe/Athens"
```

## LICENSE

[GNU General Public License, Version 2, June 1991](https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)
