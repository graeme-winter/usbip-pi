#!/usr/bin/env python3
"""End-to-end test of ser2net-gen against a real ser2net 4.x.

socat pseudo-terminals stand in for USB serial adapters, a fake sysfs tree
for the USB devices, and this script plays udev (creating the
/dev/serial/by-tcp links that ser2net-gen --link names). Needs socat and
ser2net (on PATH or SER2NET=...).

ser2net is never signalled: in 4.3.8 a SIGHUP while a client is attached
makes it abort when that client disconnects. This exercises hotplug,
unplug under a live client and replug under a new tty name, and checks
ser2net survives all of it.
"""
import os, shutil, socket, subprocess, sys, tempfile, time, tty

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OVL = os.path.join(ROOT, "board/rpi4-usbip/rootfs-overlay")
GEN = os.path.join(OVL, "usr/bin/ser2net-gen")
SER2NET = os.environ.get("SER2NET") or shutil.which("ser2net")
failures = 0
procs = {}


def check(name, cond, detail=""):
    global failures
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f": {detail}"))
    failures += not cond


def wait_for(pred, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.05)
    return False


def listening(port):
    try:
        socket.create_connection(("127.0.0.1", port), 0.3).close()
        return True
    except OSError:
        return False


def read_fd(fd, want, timeout=3.0):
    buf, end = b"", time.time() + timeout
    while time.time() < end and want not in buf:
        try:
            buf += os.read(fd, 1024)
        except BlockingIOError:
            time.sleep(0.02)
    return buf


def eof(sock, timeout=3.0):
    sock.settimeout(timeout)
    try:
        while True:
            if sock.recv(1024) == b"":
                return True
    except ConnectionResetError:
        return True
    except (socket.timeout, OSError):
        return False


class Pi:
    def __init__(self, t):
        self.t = t
        self.dev = os.path.join(t, "dev")
        os.makedirs(os.path.join(self.dev, "serial/by-tcp"))
        self.conf = os.path.join(t, "devices.conf")
        self.env = dict(os.environ, USBPI_LIB=os.path.join(OVL, "usr/lib/usbip-pi"),
                        USBPI_SYSFS=os.path.join(t, "sys"), USBPI_CONF=self.conf,
                        USBPI_TTYS=os.path.join(t, "class/tty"), USBPI_DEV=self.dev,
                        SER2NET_CONF=os.path.join(t, "run/ser2net.yaml"))

    def gen(self, *args):
        r = subprocess.run(["sh", GEN, *args], env=self.env,
                           capture_output=True, text=True)
        return r

    def plug(self, busid, vid, pid, ttyname):
        """USB device appears: sysfs, a pty for its tty, udev's link, RUN."""
        node = os.path.join(self.dev, ttyname)
        end = os.path.join(self.t, ttyname + ".end")
        p = subprocess.Popen(["socat", f"pty,raw,echo=0,link={node}",
                              f"pty,raw,echo=0,link={end}"],
                             stderr=subprocess.DEVNULL)
        procs[ttyname] = p
        assert wait_for(lambda: os.path.exists(node) and os.path.exists(end))
        iface = os.path.join(self.t, "sys", busid, f"{busid}:1.0")
        os.makedirs(os.path.join(iface, ttyname), exist_ok=True)
        for f, v in (("idVendor", vid), ("idProduct", pid), ("bDeviceClass", "00")):
            open(os.path.join(self.t, "sys", busid, f), "w").write(v + "\n")
        open(os.path.join(iface, "bInterfaceNumber"), "w").write("00\n")
        cls = os.path.join(self.t, "class/tty", ttyname)
        os.makedirs(cls)
        os.symlink(os.path.join(iface, ttyname), os.path.join(cls, "device"))
        r = self.gen("--link", ttyname)                      # udev PROGRAM
        if r.returncode == 0:
            link = os.path.join(self.dev, r.stdout.strip())
            if os.path.lexists(link):
                os.unlink(link)
            os.symlink(os.path.join("../..", ttyname), link)  # SYMLINK+="%c"
        fd = os.open(end, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        tty.setraw(fd)
        return fd

    def unplug(self, busid, ttyname):
        p = procs.pop(ttyname)
        p.kill()
        p.wait()
        shutil.rmtree(os.path.join(self.t, "class/tty", ttyname))
        shutil.rmtree(os.path.join(self.t, "sys", busid, f"{busid}:1.0", ttyname))
        for name in os.listdir(os.path.join(self.dev, "serial/by-tcp")):
            link = os.path.join(self.dev, "serial/by-tcp", name)
            if os.readlink(link).endswith("/" + ttyname):
                os.unlink(link)                               # udev drops link


def main():
    if not SER2NET or not shutil.which("socat"):
        print("skip: needs socat and ser2net")
        return 0
    t = tempfile.mkdtemp()
    pi = Pi(t)
    open(pi.conf, "w").write("serial 0403:6001 4101 115200n81,local\n"
                             "serial 2341:*    4102 9600n81,local\n"
                             "usbip  *\n")
    log = os.path.join(t, "ser2net.log")

    def start_ser2net():
        r = pi.gen()                                          # ExecStartPre
        check("config generated", r.returncode == 0, r.stderr)
        p = subprocess.Popen([SER2NET, "-d", "-c", os.path.join(t, "run/ser2net.yaml")],
                             stdout=open(log, "a"), stderr=subprocess.STDOUT)
        procs["ser2net"] = p
        return p
    try:
        s2n = start_ser2net()                                 # nothing plugged yet
        check("ports listen before devices exist",
              wait_for(lambda: listening(4101) and listening(4102)))
        check("no YAML complaints", "Unexpected" not in open(log).read(),
              open(log).read())
        c0 = socket.create_connection(("127.0.0.1", 4102))
        check("connect to absent device is closed", eof(c0))
        c0.close()

        fd_a = pi.plug("1-1.1", "0403", "6001", "ttyUSB0")
        c1 = socket.create_connection(("127.0.0.1", 4101))
        c1.sendall(b"ping-a\n")
        check("TCP -> serial", b"ping-a" in read_fd(fd_a, b"ping-a"))
        os.write(fd_a, b"pong-a\n")
        c1.settimeout(3)
        check("serial -> TCP", b"pong-a" in c1.recv(100))

        fd_b = pi.plug("1-1.2", "2341", "0043", "ttyACM0")    # hotplug, c1 live
        c2 = socket.create_connection(("127.0.0.1", 4102))
        c2.sendall(b"ping-b\n")
        check("hotplugged device reachable", b"ping-b" in read_fd(fd_b, b"ping-b"))
        c1.sendall(b"still-a\n")
        check("other connection undisturbed", b"still-a" in read_fd(fd_a, b"still-a"))
        c3 = socket.create_connection(("127.0.0.1", 4102))
        check("kickolduser drops old client", eof(c2))
        c2.close()
        c3.sendall(b"new-b\n")
        check("new client owns the port", b"new-b" in read_fd(fd_b, b"new-b"))

        pi.unplug("1-1.1", "ttyUSB0")                         # unplug, c1 live
        check("unplug: client sees EOF", eof(c1))
        c1.close()
        check("unplug: port keeps listening", wait_for(lambda: listening(4101)))
        check("ser2net survived unplug", s2n.poll() is None, s2n.returncode)

        fd_a2 = pi.plug("1-1.1", "0403", "6001", "ttyUSB3")   # replug, new tty
        c5 = socket.create_connection(("127.0.0.1", 4101))
        c5.sendall(b"back\n")
        check("replug: same TCP port reaches new tty", b"back" in read_fd(fd_a2, b"back"))
        c5.close()
        c3.close()
        time.sleep(0.5)
        check("ser2net still running", s2n.poll() is None, s2n.returncode)

        # Edit devices.conf, then "systemctl restart ser2net".
        conf = open(pi.conf).read()
        open(pi.conf, "w").write("serial 0403:6011 4110-4113\n" + conf)
        s2n.terminate()
        s2n.wait(5)
        s2n = start_ser2net()
        check("restart applies new rule", wait_for(lambda: listening(4113)))
        check("restart keeps old rules",
              wait_for(lambda: listening(4101) and listening(4102)),
              f"4101={listening(4101)} 4102={listening(4102)} log=" + open(log).read()[-400:])
        check("no assertion failures", "Assertion" not in open(log).read(),
              open(log).read()[-500:])
    finally:
        for p in procs.values():
            p.kill()
            p.wait()
        shutil.rmtree(t, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
