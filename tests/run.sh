#!/bin/sh
# Offline tests for usbip-export policy matching and usbip-keepalive port
# parsing, using a fake sysfs tree and a fake usbip binary.
# SH selects the shell under test, e.g. SH="busybox sh" tests/run.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
EXPORT=$ROOT/board/rpi4-usbip/rootfs-overlay/usr/sbin/usbip-export
KEEPALIVE=$ROOT/client/usbip-keepalive

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then echo "ok   $1"
    else echo "FAIL $1: expected '$2' got '$3'"; fail=1; fi
}

# Fake usbip: logs bind calls; "port" prints $T/port.txt.
cat > "$T/usbip" <<FAKE
#!/bin/sh
case \$1 in
  bind) echo "\$3" >> "$T/bound" ;;
  port) cat "$T/port.txt" 2>/dev/null ;;
  attach) echo "attach \$3 \$5" >> "$T/attached"; exit \${ATTACH_RC:-0} ;;
  detach) echo "detach \$3" >> "$T/detached" ;;
esac
FAKE
chmod +x "$T/usbip"
export USBIP="$T/usbip" USBIP_SYSFS="$T/sys" USBIP_EXPORT_CONF="$T/export.conf"

mkdev() { # busid vid pid class [driver]
    d=$T/sys/$1; mkdir -p "$d"
    echo "$2" > "$d/idVendor"; echo "$3" > "$d/idProduct"; echo "$4" > "$d/bDeviceClass"
    [ $# -lt 5 ] || ln -sfn "../../drivers/$5" "$d/driver"
}
mkdev 1-1.1 0403 6001 00
mkdev 1-1.2 0bda 8153 00
mkdev 1-1.3 046d c52b 00
mkdev 1-1.4 05e3 0610 09
mkdev 1-1.4.1 1a86 7523 ff
mkdev 1-1.4.2 0403 6015 00 usbip-host

export_result() { # conf busid -> "bound" or "skip"
    printf '%s\n' "$1" > "$T/export.conf"; rm -f "$T/bound"
    ${SH:-sh} "$EXPORT" "$2" >/dev/null
    if [ -s "$T/bound" ]; then echo bound; else echo skip; fi
}

check "default allow-all"         bound "$(export_result '*' 1-1.1)"
check "hub never exported"        skip  "$(export_result '*' 1-1.4)"
check "device behind hub"         bound "$(export_result '*' 1-1.4.1)"
check "already bound is skipped"  skip  "$(export_result '*' 1-1.4.2)"
check "vid:pid exact"             bound "$(export_result '0403:6001' 1-1.1)"
check "vid:pid no match -> deny"  skip  "$(export_result '0403:6001' 1-1.2)"
check "vid glob"                  bound "$(export_result '0403:*' 1-1.1)"
check "port rule"                 bound "$(export_result 'port:1-1.3' 1-1.3)"
check "port glob"                 bound "$(export_result 'port:1-1.4.*' 1-1.4.1)"
check "port rule other port"      skip  "$(export_result 'port:1-1.3' 1-1.1)"
check "deny before allow"         skip  "$(export_result "$(printf '!0bda:*\n*')" 1-1.2)"
check "deny doesn't hit others"   bound "$(export_result "$(printf '!0bda:*\n*')" 1-1.1)"
check "comments and blanks"       bound "$(export_result "$(printf '# c\n\n  0403:6001  # FTDI\n')" 1-1.1)"
check "empty conf -> deny"        skip  "$(export_result '' 1-1.1)"
check "vanished device"           skip  "$(export_result '*' 9-9)"

# Port parsing in usbip-keepalive (detach mode exercises find_port).
cat > "$T/port.txt" <<'PORT'
Imported USB devices
====================
Port 00: <Port in Use> at High Speed(480Mbps)
       Future Technology Devices International, Ltd : FT232 Serial (UART) IC (0403:6001)
       3-1 -> usbip://usbip-pi.lan:3240/1-1.2
           -> remote bus/dev 001/004
Port 01: <Port in Use> at Full Speed(12Mbps)
       Logitech, Inc. : Unifying Receiver (046d:c52b)
       3-2 -> usbip://usbip-pi.lan:3240/1-1.3
           -> remote bus/dev 001/005
Port 08: <Port in Use> at High Speed(480Mbps)
       unknown vendor : unknown product (1a86:7523)
       3-9 -> usbip://other-pi:3240/1-1.2
           -> remote bus/dev 001/006
Port 09: <Port in Use> at High Speed(480Mbps)
       unknown vendor : unknown product (1a86:7523)
       3-10 -> usbip://usbip-pi.lan:3240/1-1.22
           -> remote bus/dev 001/007
PORT
detach_ports() { rm -f "$T/detached"; ${SH:-sh} "$KEEPALIVE" detach "$1" >/dev/null
    [ -f "$T/detached" ] && tr '\n' ' ' < "$T/detached" | sed 's/ $//'; true; }
check "find port 00"              "detach 0" "$(detach_ports usbip-pi.lan:1-1.2)"
check "find port 01"              "detach 1" "$(detach_ports usbip-pi.lan:1-1.3)"
check "host disambiguation"       "detach 8" "$(detach_ports other-pi:1-1.2)"
check "busid suffix exact"        "detach 9" "$(detach_ports usbip-pi.lan:1-1.22)"
check "not attached"              ""         "$(detach_ports usbip-pi.lan:1-1.4)"

# Run loop: attaches once when missing, then stays quiet.
: > "$T/port.txt"; rm -f "$T/attached"
USBIP_POLL_INTERVAL=0.2 ${SH:-sh} "$KEEPALIVE" run usbip-pi.lan:1-1.1 > "$T/run.log" 2>&1 &
pid=$!; sleep 0.5; kill "$pid"; wait "$pid" 2>/dev/null || true
check "run attaches"              "attach usbip-pi.lan 1-1.1" "$(head -1 "$T/attached")"
check "run logs transitions only" 1 "$(grep -c attached "$T/run.log")"

rm -f "$T/attached"
ATTACH_RC=1 USBIP_POLL_INTERVAL=0.2 ${SH:-sh} "$KEEPALIVE" run usbip-pi.lan:1-1.1 > "$T/run.log" 2>&1 &
pid=$!; sleep 0.7; kill "$pid"; wait "$pid" 2>/dev/null || true
check "run retries while down"    yes "$([ "$(wc -l < "$T/attached")" -ge 2 ] && echo yes)"
check "waiting logged once"       1 "$(grep -c waiting "$T/run.log")"

check "bad arg rejected"          2 "$(${SH:-sh} "$KEEPALIVE" run nocolon >/dev/null 2>&1 || echo $?)"

exit $fail
