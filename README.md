
# [Timedate Daemon](https://cgit.radix.pro/radix/timedated.git/)

**TimeDate** Daemon is a system service that can be used to control the system time
and related settings.

This is the replacement of *systemd* service that control the **org.freedesktop.timedate1**
*D-Bus interface* for GNU Linux distributions which does not have a *systemd*.

You can find specification at: [**Freedesktop.org**](https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.timedate1.html)

**TimeDate** Daemon supports interactive parameter which can be used to control
whether *PolKit* should interactively ask the user for authentication credentials
if required. But also, if interactive way is not applicable, users permissions can
be set by *PolKit* rules in the */usr/share/polkit-1/rules.d/org.freedesktop.timedate1.rules*
file. For example, a system administrator can add Desktop-users into **wheel** group
to give them rights to access the **org.freedesktop.timedate1** *D-Bus interface*.

## Requirements:

 | Package           |      | min Version  |
 | :---              | :--: | :---         |
 | glib-2.0          |  >=  |  2.76        |
 | gobject-2.0       |  >=  |  2.76        |
 | gio-2.0           |  >=  |  2.76        |
 | polkit-gobject-1  |  >=  |  123         |
 | libpcre2-8        |  >=  |  10.36       |
 | dbus              |  >=  |  1.13.18     |

## How to Build:

```Bash
 meson setup --prefix=/usr . ..
 ninja
 ninja install
```

## Supported Distributions:

 - [Radix cross Linux](https://radix.pro)
 - [Slackware](http://www.slackware.com)
  ~~(needed litle changes in timeconfig script)~~ <br>
Update: *Slackware-current works fine now*

For other systems the special implementation of NTP daemon control should be developed.


## TODO:

~~- *timedatectl* (simply it can be writen in Bash).~~ <br>
Update: Done! 

```
loginctl --version
elogind 257 (257.14)

```

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
timedatectl list-timezones | grep Europe
Europe/Amsterdam
Europe/Andorra
Europe/Astrakhan
Europe/Athens
Europe/Belfast
Europe/Belgrade
Europe/Berlin
Europe/Bratislava
Europe/Brussels
Europe/Bucharest
Europe/Budapest
Europe/Busingen
Europe/Chisinau
Europe/Copenhagen
Europe/Dublin
Europe/Gibraltar
Europe/Guernsey
Europe/Helsinki
Europe/Isle_of_Man
Europe/Istanbul
Europe/Jersey
Europe/Kaliningrad
Europe/Kiev
Europe/Kirov
Europe/Kyiv
Europe/Lisbon
Europe/Ljubljana
Europe/London
Europe/Luxembourg
Europe/Madrid
Europe/Malta
Europe/Mariehamn
Europe/Minsk
Europe/Monaco
Europe/Moscow
Europe/Nicosia
Europe/Oslo
Europe/Paris
Europe/Podgorica
Europe/Prague
Europe/Riga
Europe/Rome
Europe/Samara
Europe/San_Marino
Europe/Sarajevo
Europe/Saratov
Europe/Simferopol
Europe/Skopje
Europe/Sofia
Europe/Stockholm
Europe/Tallinn
Europe/Tirane
Europe/Tiraspol
Europe/Ulyanovsk
Europe/Uzhgorod
Europe/Vaduz
Europe/Vatican
Europe/Vienna
Europe/Vilnius
Europe/Volgograd
Europe/Warsaw
Europe/Zagreb
Europe/Zaporozhye
Europe/Zurich

```

```
busctl get-property org.freedesktop.timedate1 /org/freedesktop/timedate1 org.freedesktop.timedate1 Timezone
s "Europe/Athens"

```

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
  sync-now                 Force immediate NTP time sync

Options:
  -h, --help               Show this help

```


## LICENSE:

[GNU General Public License Version 2, June 1991](https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)

