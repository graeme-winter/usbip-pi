# usbip-pi

A Buildroot external tree that turns a Raspberry Pi 4 into a USB/IP
appliance: plug USB 2 devices into the Pi, attach them from Linux
machines on the network as if they were local.

- Read-only root (systemd, `/var` on tmpfs), so power can be pulled safely.
- Devices are exported automatically on hotplug, filtered by a policy file.
- `usbipd` is patched to enable TCP keepalive, so a client that vanishes
  releases its device in about a minute instead of holding it forever.
- Hardware watchdog driven by systemd.
- Client-side service reattaches devices after network drops, Pi
  reboots or replugs.

## Build

Needs the usual Buildroot host packages (gcc, make, git, rsync, bc,
cpio, unzip, file, wget, perl, python3).

    ./build.sh

This clones Buildroot 2026.02.3 (LTS) into `./buildroot` if it is not
there, appends `configs/usbip_rpi4.fragment` to Buildroot's own
`raspberrypi4_64_defconfig` (so kernel, firmware and toolchain pins follow
the Buildroot release), and builds into `./output`. To use an existing
tree: `BUILDROOT=/path/to/buildroot ./build.sh`. Extra arguments go to
make, e.g. `./build.sh menuconfig` or `./build.sh linux-menuconfig`.

**SSH access:** root has no password and dropbear only accepts keys. Put
your public key(s) in `local/authorized_keys` (git-ignored) before
building. The console on HDMI/serial logs in as root without a password.

## Flash and boot

    sudo dd if=output/images/sdcard.img of=/dev/sdX bs=4M conv=fsync

The Pi takes DHCP on `eth0` and is called `usbip-pi`. Then:

    ssh root@<pi>
    usbip list -l          # what is plugged in, with bus ids
    lsusb -t               # topology; useful for port rules
    journalctl -u 'usbip-export@*'

On a Pi 4, USB 2 devices in any of the four ports show up as bus ids
like `1-1.N` (behind the on-board VL805 hub). Check which physical port
is which with `lsusb -t` rather than trusting a diagram.

## Export policy

`board/rpi4-usbip/rootfs-overlay/etc/usbip/export.conf`; first match
wins, no match means not exported:

    0403:6001      # by VID:PID (lowercase hex, globs ok)
    port:1-1.3     # by physical port
    !0bda:*        # deny
    *              # everything (the shipped default)

Hubs are never exported; devices behind an external hub are handled
individually.

To change it on a running Pi (the root filesystem is read-only):

    mount -o remount,rw /
    vi /etc/usbip/export.conf
    mount -o remount,ro /
    udevadm trigger --action=add --subsystem-match=usb

A change made this way lasts until the image is reflashed, so also
update the overlay copy.

## Client (Linux)

Install the distro USB/IP tools (Debian/Fedora `usbip`, Ubuntu
`linux-tools-generic`), then:

    sudo client/install.sh
    sudo systemctl enable --now usbip-client@usbip-pi.lan:1-1.2

Use one instance per device. `usbip-keepalive` polls every 5 s
(`USBIP_POLL_INTERVAL`), attaches if the device is missing, logs only
state changes, and detaches when the unit stops. One-off use without the
service: `sudo usbip attach -r usbip-pi.lan -b 1-1.2`.

`install.sh` also sets short TCP keepalive sysctls on the client. They
only affect sockets that request keepalive, but they are system-wide.

Windows clients can use usbip-win2; the reattach logic here is Linux-only.

## Limitations and notes

- **No authentication or encryption.** usbipd listens on TCP 3240 and
  will hand any exported device to anyone who asks. Keep it on an
  isolated VLAN, or add WireGuard (`CONFIG_WIREGUARD` plus
  `BR2_PACKAGE_WIREGUARD_TOOLS`) and bind the client to the tunnel.
- **One client per device.** A device in use cannot be attached elsewhere.
- **Isochronous devices** (webcams, audio) are latency-sensitive and
  often misbehave over USB/IP. Bulk and interrupt devices (serial
  adapters, HID, storage, most instruments) work well.
- **SSH host keys** live on tmpfs because the root is read-only, so they
  change every boot. For stable keys, mount persistent storage on `/var`
  (see `BR2_INIT_SYSTEMD_VAR_FACTORY` help) or bake keys into the overlay
  (but not for an image you share).
- USB 3 devices are not a goal here; in the blue ports they enumerate on
  bus 2 and may or may not behave.

## Layout

    build.sh                      configure + build wrapper
    configs/usbip_rpi4.fragment   additions to raspberrypi4_64_defconfig
    board/rpi4-usbip/
      linux.fragment              USBIP_HOST, watchdog
      post-build.sh               enable usbipd, install SSH keys
      rootfs-overlay/             udev rule, units, usbip-export, sysctl
    patches/usbip/                usbipd keepalive patch (via BR2_GLOBAL_PATCH_DIR)
    client/                       usbip-keepalive, systemd template, installer
    tests/run.sh                  offline tests (SH="busybox sh" to test ash)
