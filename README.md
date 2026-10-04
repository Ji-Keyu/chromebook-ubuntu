# Low-Power Chromebook Ubuntu Servers

## Hardware

Chromebooks I am using:

- Acer Chromebook 311 — Intel Celeron N4020, 4 GB RAM, 32 GB eMMC
- Acer Chromebook 511 / C734 — Intel Celeron N4500, 4 GB RAM, 32 GB eMMC

## Power Consumption

I am interested in seeing just how low I can get the idle power consumption of these machines, because electricity in the Bay Area is hella expensive.

I use:

```bash
upower -i /org/freedesktop/UPower/devices/battery_BAT0
```

to check the battery status.

While the Chromebook is unplugged and running entirely from its battery, I use the `energy-rate` value as an estimate of whole-system power consumption.

Lowest battery discharge rate observed at idle so far:

| Device | Lowest observed idle power |
|---|---:|
| Acer Chromebook 311 | 0.266 W |
| Acer Chromebook 511 / C734 | 0.461 W |

The 311 generally fluctuates around 0.3 W. The 511 fluctuates more, typically around 0.5 W.

The biggest power-saving measure I have found so far is disabling the display pipeline. Disabling Bluetooth may also save a small amount of power.

## Ubuntu Server Installation

Using the MrChromebox guide and firmware, I installed Ubuntu Server 26.04 on both machines.

During installation:

- I selected the **minimized** Ubuntu Server installation.
- I installed `openssh-server`.
- I did **not** connect to Wi-Fi during installation.

I encountered Wi-Fi connection issues in the installer on both Chromebooks, so I skipped networking during installation.

After installation was complete, rather than digging out a USB-to-Ethernet adapter, I manually created the Netplan YAML configuration needed to connect each Chromebook to Wi-Fi.

Once Wi-Fi was working, I SSHed into each machine, transferred `init.sh`, and ran:

```bash
chmod +x init.sh
sudo ./init.sh
```

## `init.sh`

`init.sh` handles the rest of the server setup and is intended to be safe to rerun.

It currently does the following:

- Runs `apt update` and `apt upgrade -y` before installing anything else.
- Installs:
  - `htop`
  - `nano`
  - `tmux`
  - `locales`
  - `curl`
  - `git`
  - `rfkill`
  - `upower`
  - `iw`
- Configures `en_US.UTF-8`.
- Installs `uv`.
- Configures systemd-logind to ignore lid-close events.
- Sets the battery charge limit to 60%.
- Turns the backlight off and disables the internal eDP display pipeline at boot.
- Blocks the Bluetooth radio at boot and disables the Bluetooth daemon.
- Adds several useful shell aliases:
  - `screenoff`
  - `screenon`
  - `battery`
- Verifies the resulting configuration after setup.

The battery charge limit is useful because these machines are intended to remain plugged in most of the time.

For the display, setting the backlight brightness to `0` alone is not enough. The script also disables the eDP connector:

```bash
echo 0 > /sys/class/backlight/intel_backlight/brightness
echo off > /sys/class/drm/card1-eDP-1/status
```

This allows the panel/display pipeline to enter a lower-power state and has made the largest difference to idle power consumption so far.

The corresponding aliases let me temporarily turn the screen back on when needed:

```bash
screenon
screenoff
```

The script also sets:

```text
/sys/class/power_supply/BAT0/charge_control_end_threshold
```

to `60`, so the battery normally stops charging around 60% while the Chromebook is being used as an always-on server.

A reboot after running the script verifies that all of the systemd services and boot-time power-saving settings work correctly.
