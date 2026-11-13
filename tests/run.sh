#!/bin/sh
# Offline tests for device routing (usbip-export), ser2net config
# generation (ser2net-gen) and the client port parsing (usbip-keepalive),
# using a fake sysfs tree and fake usbip/systemctl binaries.
#
# SH selects the shell under test, e.g. SH="busybox sh" tests/run.sh
# BUILDROOT=/path/to/buildroot also runs Buildroot's check-merged.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
OVL=$ROOT/board/rpi4-usbip/rootfs-overlay
EXPORT=$OVL/usr/bin/usbip-export
GEN=$OVL/usr/bin/ser2net-gen
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
# Fake systemctl: is-active per \$ACTIVE, logs everything else.
cat > "$T/systemctl" <<FAKE
#!/bin/sh
case \$1 in
  is-active) [ -n "\${ACTIVE:-}" ] ;;
  *) echo "\$*" >> "$T/systemctl.log" ;;
esac
FAKE
# Fake logger: syslog lines go to stderr where the tests can see them.
printf '#!/bin/sh\nshift 3\necho "$*" >&2\n' > "$T/logger"
chmod +x "$T/usbip" "$T/systemctl" "$T/logger"
export USBIP="$T/usbip" SYSTEMCTL="$T/systemctl" LOGGER="$T/logger" \
       USBPI_LIB="$OVL/usr/lib/usbip-pi" USBPI_SYSFS="$T/sys" \
       USBPI_CONF="$T/devices.conf" USBPI_TTYS="$T/class/tty" \
       SER2NET_CONF=unused

mkdev() { # busid vid pid class [driver]
    d=$T/sys/$1; mkdir -p "$d"
    echo "$2" > "$d/idVendor"; echo "$3" > "$d/idProduct"; echo "$4" > "$d/bDeviceClass"
    [ $# -lt 5 ] || ln -sfn "../../drivers/$5" "$d/driver"
}
mktty() { # busid ifnum tty   (usb-serial style: tty under the interface)
    i=$T/sys/$1/$1:1.$((0x$2)); mkdir -p "$i/$3" "$T/class/tty/$3"
    echo "$2" > "$i/bInterfaceNumber"
    case $3 in
        ttyACM*) ln -sfn "$i" "$T/class/tty/$3/device" ;;
        *)       ln -sfn "$i/$3" "$T/class/tty/$3/device" ;;
    esac
}

########################################################################
# Routing: usbip-export
mkdev 1-1.1 0403 6001 00
mkdev 1-1.2 0bda 8153 00
mkdev 1-1.3 046d c52b 00
mkdev 1-1.4 05e3 0610 09
mkdev 1-1.4.1 1a86 7523 ff
mkdev 1-1.4.2 0403 6015 00 usbip-host

export_result() { # conf busid -> "bound" or "skip"
    printf '%s\n' "$1" > "$USBPI_CONF"; rm -f "$T/bound"
    ${SH:-sh} "$EXPORT" "$2" >/dev/null 2>&1
    if [ -s "$T/bound" ]; then echo bound; else echo skip; fi
}

check "default usbip *"           bound "$(export_result 'usbip *' 1-1.1)"
check "hub never exported"        skip  "$(export_result 'usbip *' 1-1.4)"
check "device behind hub"         bound "$(export_result 'usbip *' 1-1.4.1)"
check "already bound is skipped"  skip  "$(export_result 'usbip *' 1-1.4.2)"
check "vanished device"           skip  "$(export_result 'usbip *' 9-9)"
check "vid:pid exact"             bound "$(export_result 'usbip 0403:6001' 1-1.1)"
check "no match -> ignore"        skip  "$(export_result 'usbip 0403:6001' 1-1.2)"
check "vid glob"                  bound "$(export_result 'usbip 0403:*' 1-1.1)"
check "port rule"                 bound "$(export_result 'usbip port:1-1.3' 1-1.3)"
check "port glob"                 bound "$(export_result 'usbip port:1-1.4.*' 1-1.4.1)"
check "serial keeps it local"     skip  "$(export_result "$(printf 'serial port:1-1.3 4001\nusbip *')" 1-1.3)"
check "serial rule spares others" bound "$(export_result "$(printf 'serial port:1-1.3 4001\nusbip *')" 1-1.1)"
check "ignore before usbip"       skip  "$(export_result "$(printf 'ignore 0bda:*\nusbip *')" 1-1.2)"
check "comments and blanks"       bound "$(export_result "$(printf '# c\n\n  usbip  0403:6001  # FTDI\n')" 1-1.1)"
check "unknown action skipped"    bound "$(export_result "$(printf 'export *\nusbip *')" 1-1.1)"
check "empty conf -> ignore"      skip  "$(export_result '' 1-1.1)"
printf 'usbip *' > "$USBPI_CONF"; rm -f "$T/bound"   # no trailing newline
${SH:-sh} "$EXPORT" 1-1.1 >/dev/null
check "last line w/o newline"     1-1.1 "$(cat "$T/bound")"
mkdir -p "$T/glob-trap" && touch "$T/glob-trap/x"
printf 'usbip *\n' > "$USBPI_CONF"; rm -f "$T/bound"
(cd "$T/glob-trap" && ${SH:-sh} "$EXPORT" 1-1.1 >/dev/null)
check "'*' not glob-expanded"     1-1.1 "$(cat "$T/bound")"

########################################################################
# ser2net-gen
rm -rf "$T/sys" "$T/class"
mkdev 1-1.1 0403 6001 00; mktty 1-1.1 00 ttyUSB0          # FT232
mkdev 1-1.2 0403 6011 00                                   # FT4232, 4 ports,
mktty 1-1.2 02 ttyUSB1; mktty 1-1.2 00 ttyUSB3             #   ttys numbered
mktty 1-1.2 03 ttyUSB2; mktty 1-1.2 01 ttyUSB4             #   out of order
mkdev 1-1.3 2341 0043 02; mktty 1-1.3 00 ttyACM0          # Arduino (ACM)
mkdev 1-1.4 0403 6001 00; mktty 1-1.4 00 ttyUSB5          # 2nd FT232
mkdev 1-1.5 1a86 7523 ff; mktty 1-1.5 00 ttyUSB6          # routed to usbip
mkdev 1-1.6 10c4 ea70 00                                   # CP2105 dual, but
mktty 1-1.6 00 ttyUSB7; mktty 1-1.6 01 ttyUSB8             #   one port rule
mkdev 1-1.7 1d50 6018 02                                   # dual CDC-ACM:
mktty 1-1.7 00 ttyACM1; mktty 1-1.7 02 ttyACM2             #   ifaces 0 and 2

cat > "$USBPI_CONF" <<'CONF'
serial  port:1-1.2  4010-4013  115200n81,local  rfc2217
serial  0403:6001   4001       9600n81,local         # FTDI
serial  2341:*      4020
serial  10c4:ea70   4025
serial  1d50:6018   4030-4032
serial  067b:2303
serial  0bda:*      4012-4014                        # overlaps 4010-4013
serial  1234:*      4040       9600n81 bogus
usbip   *
CONF

export SER2NET_CONF="$T/run/ser2net.yaml" USBPI_DEV="$T/dev"
Y=$SER2NET_CONF
dev=$T/dev/serial/by-tcp
gen() { ${SH:-sh} "$GEN" 2> "$T/gen.err"; }
conn() { # tcpport -> "accepter|connector"
    awk -v p="&port$1" '$1 == "connection:" { on = ($2 == p) }
        on && $1 == "accepter:" { a = $2 } on && $1 == "connector:" { c = $2 }
        END { if (a != "") print a "|" c }' "$Y"; }
link() { ${SH:-sh} "$GEN" --link "$1" 2>> "$T/gen.err"; }
ports() { awk '$1 == "connection:" { sub("&port", "", $2); printf "%s ", $2 }' "$Y" | sed 's/ $//'; }

gen
check "yaml header"               "%YAML 1.1" "$(head -1 "$Y")"
check "never an empty document"   1 "$(grep -c '^default:' "$Y")"
check "ports from conf alone"     "4010 4011 4012 4013 4001 4020 4025 4030 4031 4032 4014" "$(ports)"
check "range, rfc2217"            "telnet(rfc2217),tcp,4013|serialdev,$dev/4013,115200n81,local" "$(conn 4013)"
check "single port, settings"     "tcp,4001|serialdev,$dev/4001,9600n81,local" "$(conn 4001)"
check "defaults"                  "tcp,4020|serialdev,$dev/4020,9600n81,local" "$(conn 4020)"
check "kickolduser per port"      11 "$(grep -c 'kickolduser: true' "$Y")"
check "overlap warned"            2 "$(grep -c 'line 7: TCP 401[23] already used' "$T/gen.err")"
check "missing port warned"       1 "$(grep -c "line 6: bad or missing TCP port ''" "$T/gen.err")"
check "bad mode warned"           1 "$(grep -c "line 8: bad mode 'bogus'" "$T/gen.err")"

check "link: FT232"               "serial/by-tcp/4001" "$(link ttyUSB0)"
check "link: FT4232 if00"         "serial/by-tcp/4010" "$(link ttyUSB3)"
check "link: FT4232 if02"         "serial/by-tcp/4012" "$(link ttyUSB1)"
check "link: FT4232 if03"         "serial/by-tcp/4013" "$(link ttyUSB2)"
check "link: ACM"                 "serial/by-tcp/4020" "$(link ttyACM0)"
check "link: dual ACM if02 -> +2" "serial/by-tcp/4032" "$(link ttyACM2)"
check "link: CP2105 if00"         "serial/by-tcp/4025" "$(link ttyUSB7)"
check "link: CP2105 if01 refused" 1 "$(link ttyUSB8 >/dev/null || echo $?)"
check "out of range explained"    1 "$(grep -c 'interface 1 -> TCP 4026 is outside 4025' "$T/gen.err")"
check "link: usbip device none"   1 "$(link ttyUSB6 >/dev/null || echo $?)"
check "link: unknown tty none"    1 "$(link ttyUSB99 >/dev/null || echo $?)"
mkdir -p "$dev"; ln -sfn ../../ttyUSB0 "$dev/4001"
check "link: same tty again"      "serial/by-tcp/4001" "$(link ttyUSB0)"
check "link: port held by live"   1 "$(link ttyUSB5 >/dev/null || echo $?)"
check "held port explained"       1 "$(grep -c 'TCP 4001 already used by ttyUSB0' "$T/gen.err")"
rm -rf "$T/class/tty/ttyUSB0"                      # first FTDI unplugged
check "link: stale holder freed"  "serial/by-tcp/4001" "$(link ttyUSB5)"

printf 'usbip *\n' > "$USBPI_CONF"; gen
check "no serial rules: valid"    "" "$(ports)"
check "no serial rules: default"  1 "$(grep -c '^default:' "$Y")"
printf 'serial * 4001' > "$USBPI_CONF"; gen      # no trailing newline
check "last line w/o newline"     4001 "$(ports)"
for spec in 0 4001- -4001 4005-4001 70000 40a1 4001-4002-4003; do
    printf 'serial * %s\n' "$spec" > "$USBPI_CONF"; gen
    check "bad range '$spec' rejected" "" "$(ports)"
done
check "bad argument"              2 "$(${SH:-sh} "$GEN" --bogus 2>/dev/null || echo $?)"

########################################################################
# Client: port parsing in usbip-keepalive (detach mode exercises it)
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

########################################################################
# Overlay must suit merged /usr + merged /usr/bin (forced by systemd).
if [ -n "${BUILDROOT:-}" ]; then
    if "$BUILDROOT/support/scripts/check-merged" -t overlay -u -b "$OVL" >/dev/null; then
        echo "ok   overlay passes check-merged"
    else
        echo "FAIL overlay fails check-merged"; fail=1
    fi
elif [ -e "$OVL/usr/sbin" ]; then
    echo "FAIL overlay has usr/sbin (must be merged into usr/bin)"; fail=1
fi

exit $fail
