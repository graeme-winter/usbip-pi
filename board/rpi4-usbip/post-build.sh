#!/bin/sh
# Enable the appliance services and install optional SSH keys.
set -eu

TARGET_DIR=$1
BOARD_DIR=$(cd "$(dirname "$0")" && pwd)
EXT_DIR=$(cd "$BOARD_DIR/../.." && pwd)

wants=$TARGET_DIR/etc/systemd/system/multi-user.target.wants
mkdir -p "$wants"
ln -sf /usr/lib/systemd/system/usbipd.service "$wants/usbipd.service"

# Root has no password; SSH (dropbear) only accepts keys. Put yours in
# local/authorized_keys (git-ignored) to bake them into the image.
if [ -f "$EXT_DIR/local/authorized_keys" ]; then
    install -d -m 700 "$TARGET_DIR/root/.ssh"
    install -m 600 "$EXT_DIR/local/authorized_keys" \
        "$TARGET_DIR/root/.ssh/authorized_keys"
fi
