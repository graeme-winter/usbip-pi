# usbip-pi

A Buildroot external tree that turns a Raspberry Pi 4 into a USB-over-
Ethernet appliance. Plug USB 2 devices into the Pi; each one is either
exported whole over USB/IP (attach it from a Linux client as if it were
local) or, for USB-serial adapters, published as TCP ports by ser2net
(usable from anything, e.g. EPICS `drvAsynIPPortConfigure`).

- Read-only root (systemd, `/var` on tmpfs), so power can be pulled safely.
- One file, `devices.conf`, routes each device to USB/IP, ser2net or nowhere;
  devices are handled automatically on hotplug.
- Serial ports keep a fixed TCP port per rule, whatever ttyUSB number the
  kernel assigns, and survive unplug/replug.
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
    journalctl -u 'usbip-export@*'      # routing decisions
    journalctl -t ser2net-gen -u ser2net  # serial ports
    ls -l /dev/serial/by-tcp/           # published serial ports

On a Pi 4, USB 2 devices in any of the four ports show up as bus ids
like `1-1.N` (behind the on-board VL805 hub). Check which physical port
is which with `lsusb -t` rather than trusting a diagram.

## Routing devices: devices.conf

`board/rpi4-usbip/rootfs-overlay/etc/usbip-pi/devices.conf` decides where
each device goes. First match wins; no match means ignore:

    #ACTION MATCH        PORTS      SETTINGS          MODE
    serial  port:1-1.1   4001       115200n81,local
    serial  0403:6011    4010-4013  9600n81,local     rfc2217
    ignore  0bda:*
    usbip   *                       # the shipped default line

- **MATCH** is a VID:PID (lowercase hex) or `port:BUSID`; globs work.
  Hubs are never exported; devices behind an external hub are handled
  individually.
- **usbip** binds the whole device to usbip-host for clients to attach.
- **serial** leaves the device on its Pi kernel driver (FTDI, CP210x,
  CH341, PL2303, CDC-ACM) and ser2net publishes its port(s). USB
  interface N goes to the first port + N, so give multi-port adapters a
  range: FT2232 two ports, FT4232 four; a dual CDC-ACM device uses
  interfaces 0 and 2. Each port is linked on the Pi as
  `/dev/serial/by-tcp/<port>`.
- **SETTINGS** are ser2net serialdev options, comma-separated without
  spaces (default `9600n81,local`; e.g. `115200n81,local,rtscts`).
- **MODE** is `raw` (default, plain TCP: what EPICS asyn IP ports want),
  `rfc2217` (telnet with RFC 2217, so the client can set baud and
  DTR/RTS, e.g. pyserial's `rfc2217://pi:4010`), or `telnet`.

ser2net listens on every port of every serial rule from boot, whether
or not the device is plugged in. A client connecting to an absent device
gets an error message and is disconnected; unplugging under a connected
client closes that client; after a replug the same TCP port works again.
Only one client per serial port: a new connection takes the port over
from the old one (`kickolduser`), which suits IOCs that reconnect after
a restart.

To change it on a running Pi (the root filesystem is read-only):

    mount -o remount,rw /
    vi /etc/usbip-pi/devices.conf
    mount -o remount,ro /
    systemctl restart ser2net             # if serial rules changed
    udevadm trigger --action=add --subsystem-match=usb --subsystem-match=tty

A device already bound to USB/IP stays bound until it is replugged (or
`usbip unbind -b BUSID`). A change made on the Pi lasts until the image
is reflashed, so also update the overlay copy.

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
  will hand any exported device to anyone who asks; ser2net ports are
  equally open. Keep it on an
  isolated VLAN, or add WireGuard (`CONFIG_WIREGUARD` plus
  `BR2_PACKAGE_WIREGUARD_TOOLS`) and bind the client to the tunnel.
- **One client per device.** A USB/IP device in use cannot be attached
  elsewhere; a serial port goes to the most recent connection.
- **ser2net is never reloaded.** Buildroot ships ser2net 4.3.8, which
  aborts if it gets a SIGHUP while any client is connected and that
  client later disconnects (fixed upstream in 4.6.7, commit 7cc838f).
  Hence the static configuration: edits to serial rules need
  `systemctl restart ser2net`, which drops open serial connections.
  Don't add an ExecReload to the unit.
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
      linux.fragment              USBIP_HOST, USB serial drivers, watchdog
      post-build.sh               enable usbipd + ser2net, install SSH keys
      rootfs-overlay/             (no usr/sbin: systemd forces merged /usr/bin)
        etc/usbip-pi/devices.conf routing policy
        usr/lib/usbip-pi/policy.sh shared rule matching
        usr/bin/usbip-export      binds devices routed to usbip
        usr/bin/ser2net-gen       ser2net config + /dev/serial/by-tcp names
        etc/udev/rules.d/         hotplug hooks for both
    patches/usbip/                usbipd keepalive patch (via BR2_GLOBAL_PATCH_DIR)
    client/                       usbip-keepalive, systemd template, installer
    tests/run.sh                  offline tests with fake sysfs
    tests/e2e_ser2net.py          real ser2net + socat ptys

## Tests

    tests/run.sh                          # dash
    SH="busybox sh" tests/run.sh          # the target's shell
    BUILDROOT=./buildroot tests/run.sh    # also Buildroot's check-merged
    tests/e2e_ser2net.py                  # needs ser2net and socat

The end-to-end test drives a real ser2net with socat pseudo-terminals as
adapters, playing udev itself: hotplug next to a live connection,
kickolduser, unplug under a client, replug under a new tty name, restart
after a config edit.
