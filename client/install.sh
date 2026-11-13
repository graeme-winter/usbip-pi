#!/bin/sh
# Install the USB/IP keep-attached client on a systemd Linux machine.
# Needs the distro usbip tools (Debian/Fedora: usbip; Ubuntu: linux-tools-generic).
set -eu
cd "$(dirname "$0")"
command -v usbip >/dev/null || echo "warning: usbip not found in PATH" >&2
install -m 755 usbip-keepalive /usr/local/sbin/usbip-keepalive
install -m 644 usbip-client@.service /etc/systemd/system/usbip-client@.service
install -m 644 90-usbip-keepalive.conf /etc/sysctl.d/90-usbip-keepalive.conf
echo vhci-hcd > /etc/modules-load.d/usbip-vhci.conf
modprobe vhci-hcd
sysctl -q --system
systemctl daemon-reload
echo "Now: systemctl enable --now usbip-client@<pi-host>:<busid>"
