# Redragon H510-PRO — Linux volume fix

**Everything here was done by Claude. Run it on your own risk!**

Tested on Fedora Workstation 43.

Fixes the Redragon H510-PRO (2.4GHz dongle) only producing audio at 100%
volume, and going silent when switching between analog and S/PDIF
outputs. Cause: a known "sticky" hardware volume bug in the dongle
(visible in `dmesg`). Fix: lock the hardware at 100% and let
PipeWire/WirePlumber control volume in software instead.

Requires systemd + udev + PipeWire/WirePlumber (default on most modern
Linux desktops).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/andreyadriano/redragon-h510-pro-audio-fix/master/h510-pro-audio-fix.sh | sudo bash
```

Then unplug/replug the dongle and adjust volume normally from your sound
panel. Use the **analog** output profile — avoid S/PDIF, it's not a real
digital DAC on this dongle.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/andreyadriano/redragon-h510-pro-audio-fix/master/h510-pro-audio-fix.sh | sudo bash -s -- --uninstall
```

## Troubleshooting

```bash
journalctl -t h510-volume-fix -n 10
journalctl --user -u h510-volume-recheck.service -n 10
```
