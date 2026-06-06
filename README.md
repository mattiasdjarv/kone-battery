# kone-battery

Battery monitor for the Roccat Kone Pro Air on Linux.

I couldn't find anything that worked so I made this script. When in 2.4GHz wireless
mode, the mouse exposes battery and charging state over a vendor HID
interface that `upower` does not read. `kone-daemon` listens to it and
writes the latest value to a per-user cache file. The other scripts read
that file and put the value in a status bar, a tmux status line, a
terminal command, or a desktop notification.

It works for me. That is about all I can promise.

## Dependencies

- `hidapi`, installed by `install.sh`
- `notify-send`, only for the low-battery notification

## Install

    git clone https://github.com/mattiasdjarv/kone-battery.git
    cd kone-battery
    ./install.sh

The installer copies the scripts to `~/.local/bin/`, installs `hidapi`, and
offers to set up a systemd user service and a udev rule. Both default to no.

    ./uninstall.sh

## Autostart

`kone-daemon` must be running for the rest of the scripts to work. Pick one.

systemd user service (the installer can do this for you):

    mkdir -p ~/.config/systemd/user
    cp kone-daemon.service ~/.config/systemd/user/
    systemctl --user daemon-reload
    systemctl --user enable --now kone-daemon.service

Window manager, no systemd. Hyprland:

    exec-once = ~/.local/bin/kone-daemon

i3 / sway:

    exec ~/.local/bin/kone-daemon &

GNOME: drop a `.desktop` file into `~/.config/autostart/`.

## Scripts

| Script        | Purpose                                                                 |
| ------------- | ----------------------------------------------------------------------- |
| `kone-daemon` | Background listener. Writes the cache file.                             |
| `kone-status` | Print the cached battery status, or `No data` if the daemon hasn't reported. Safe for status bars and one-shot CLI use. |
| `kone-notify` | Desktop notification on low battery / charging.                        |

### Waybar

    "modules-right": ["custom/kone"],
    "custom/kone": {
        "exec": "~/.local/bin/kone-status",
        "interval": 5
    }

### Polybar

    [module/kone]
    type = custom/script
    exec = ~/.local/bin/kone-status
    interval = 5

### i3blocks

    [kone]
    command=~/.local/bin/kone-status
    interval=5

### tmux

    set -g status-right '#(kone-status) | %H:%M'

### Command line

    $ kone-status
    40%
    # Prints 'No data' if the daemon has not reported yet.

### Low-battery notification

Add `kone-notify` to your autostart. Sends a notification when the battery
drops below 20% and another when charging starts. Threshold and poll interval
overrideable via `KONE_LOW_THRESHOLD` and `KONE_POLL_INTERVAL`. Needs
`notify-send`.

## Permissions

If you get a permission error opening `/dev/hidrawN`, install the udev rule:

    sudo cp 99-kone-pro-air.rules /etc/udev/rules.d/
    sudo udevadm control --reload-rules
    sudo udevadm trigger

Then unplug and replug the dongle.

## Compatibility

I only have the Roccat Kone Pro Air, so that is all I know this works with.
The protocol is undocumented and the daemon matches on USB vendor/product IDs
`1e7d:2c8e`; other mice in the Kone family might too. If you try one, open an
issue and let me know. Also, battery level is reported by the mouse in 10% increments.

## Troubleshooting

If `kone-status` says `No data`:

- The mouse sends a battery packet when it reconnects or wakes from standby. Unplug the dongle and replug it, or turn the mouse off and on.
- Check it is running: `pgrep -fl kone-daemon` or `systemctl --user status kone-daemon`
- Read the logs: `journalctl --user -u kone-daemon -n 50` (systemd) or your window manager's startup log (WM autostart)

## License

MIT.
