from __future__ import print_function
from socket import *
import os, struct, time, select

# python2 doesn't support monotonic time, just use the wall clock
if 'monotonic' not in dir(time): time.monotonic=time.time

# Use netlink to wait for added or deleted interfaces, return tuple of (added,
# name), where "added" is a boolean, and "name" is a string. If timeout given,
# returns None after that many seconds.
class nic():

    def __init__(self):
        self.sock=socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE)
        self.sock.bind((os.getpid(), 1)) # RTMGRP_LINK

    def change(self, timeout=None):
        if timeout: timeout += time.monotonic()
        while True:
            s = select.select([self.sock],[],[], timeout-time.monotonic() if timeout else None)
            if not s[0]: return None
            data=self.sock.recv(65535)
            plen, ptype = struct.unpack("=LH", data[:6])
            if plen != len(data): continue
            if ptype == 16: added = True
            elif ptype == 17: added = False
            else: continue
            data=data[32:]
            # Data may contain multiple params, consisting of a short len, a
            # short type, and len-4 bytes of data (always padded to multiple of
            # 4 bytes)
            while len(data) > 4:
                rlen, rtype = struct.unpack("=HH", data[:4]) # get the len and type
                if rlen < 4 or rlen > len(data): break       # done if end of data or bogus
                # rtype 3 is an interface name, return it
                if rtype == 3: return (added, data[4:rlen].split(b"\x00")[0].decode("ascii"))
                # else advance to next
                rlen=(rlen+3)//4 # round up to multiple of 4
                data = data[rlen:]

    # return list of all attached network interfaces
    # XXX eventually from netlink, but for now scrape from sysfs
    def attached(self):
        try:
            return os.listdir("/sys/class/net")
        except OSError:
            raise OSError("No sysfs")

    # return list of interfaces slaved to specified bridge
    # XXX eventually from netlink, but for now scrape from sysfs
    def bridged(bridge):
        try:
            return os.listdir("/sys/class/net/%s/brif" % bridge)
        except OSError:
            raise OSError("Invalid bridge %s" % bridge)

if __name__ == "__main__":
    n=nic()
    print("Attached network interfaces:", str(n.attached())[1:-1])
    if "br0" in n.attached(): print("Intefaces slaved to br0:", str(n.bridged("br0"))[1:-1])
    print("Waiting 10 seconds for an interface change...")
    change=n.change(10)
    if not change:
        print("Nothing happened")
    else:
        print("%s was %s" % (change[1], "added" if change[0] else "removed"))
