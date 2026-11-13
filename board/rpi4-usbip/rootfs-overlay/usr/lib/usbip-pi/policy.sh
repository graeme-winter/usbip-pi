# Device routing policy for usbip-pi; sourced by usbip-export and
# ser2net-gen. See /etc/usbip-pi/devices.conf for the file format.
# shellcheck shell=sh
# shellcheck disable=SC2034  # POLICY_* are read by the sourcing scripts

USBPI_SYSFS=${USBPI_SYSFS:-/sys/bus/usb/devices}
USBPI_CONF=${USBPI_CONF:-/etc/usbip-pi/devices.conf}

# policy_lookup BUSID
#
# Sets POLICY_ID (vid:pid), POLICY_ACTION (usbip|serial|ignore),
# POLICY_LINE (matching line number, empty for the default) and, for
# serial, POLICY_TCPPORT, POLICY_SETTINGS and POLICY_MODE. Returns 1 if
# the device is not present.
policy_lookup() {
    _busid=$1
    _dev=$USBPI_SYSFS/$_busid
    POLICY_ID='' POLICY_ACTION=ignore POLICY_LINE=''
    POLICY_TCPPORT='' POLICY_SETTINGS='' POLICY_MODE=''
    [ -r "$_dev/idVendor" ] || return 1
    POLICY_ID=$(cat "$_dev/idVendor"):$(cat "$_dev/idProduct")
    [ -r "$USBPI_CONF" ] || return 0

    _n=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        _n=$((_n + 1))
        _line=${_line%%#*}
        # Split into fields without glob-expanding a "*" match.
        set -f
        # shellcheck disable=SC2086
        set -- $_line
        set +f
        [ $# -ge 2 ] || continue

        case $2 in
            port:*) _subject=port:$_busid ;;
            *)      _subject=$POLICY_ID ;;
        esac
        # shellcheck disable=SC2254
        case $_subject in
            $2) ;;
            *) continue ;;
        esac

        case $1 in
            usbip|serial|ignore) ;;
            *) echo "devices.conf:$_n: unknown action '$1'" >&2; continue ;;
        esac
        POLICY_ACTION=$1
        POLICY_LINE=$_n
        if [ "$1" = serial ]; then
            POLICY_TCPPORT=${3:-}
            POLICY_SETTINGS=${4:-9600n81,local}
            POLICY_MODE=${5:-raw}
        fi
        return 0
    done < "$USBPI_CONF"
    return 0
}
