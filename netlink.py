from __future__ import print_function
import os, sys, struct, socket, time, select, fnmatch
# receive network interface status via netlink

# python2 doesn't support monotonic time, use the wall clock for timeouts
if 'monotonic' not in dir(time): time.monotonic=time.time

# return true if string s matches any listed glob
def matches(s, globs):
    for g in globs:
        if fnmatch.fnmatch(s, g):
            return True
    return False

# Used to request the netlink type, RTMGRP_XXX constants from rtnetlink.h
LINK = 0x01 # RTMGRP_LINK
IPV4 = 0x10 # RTMGRP_IPV4_IFADDRS

# Fields in struct nlmsghdr minus the "nlmsg_" (netlink.h)
_nlmsg_struct = [ "len", "type", "flags", "seq", "pid" ]

# Fields in struct ifinfomsg, minus the "ifi_" (rtnetlink.h)
_ifi_struct = [ "family", "type", "index", "flags", "changes" ]

# Bits in ifi_flags, starting with the LSB (if_link.h)
_iff_bits = [ "up", "broadcast", "debug", "loopback", "pointopoint",
              "notrailers", "running", "noarp", "promisc", "allmulti",
              "master", "slave", "multicast", "portsel", "automedia",
              "dynamic", "lower_up", "dormant", "echo" ]

# Lowercase versions of IFLA_XXX enums, minus the "IFLA_" (if_link.h)
ifla_enum = [ "unspec", "address", "broadcast", "ifname", "mtu", "link",
              "qdisc", "stats", "cost", "priority", "master", "wireless",
              "protinfo", "txqlen", "map", "weight", "operstate", "linkmode",
              "linkinfo", "net_ns_pid", "ifalias", "num_vf", "vfinfo_list",
              "stats64", "vf_ports", "port_self", "af_spec", "group",
              "net_ns_fd", "ext_mask", "promiscuity", "num_tx_queues",
              "num_rx_queues", "carrier", "phys_port_id", "carrier_changes",
              "phys_switch_id", "link_netnsid", "phys_port_name", "proto_down",
              "gso_max_segs", "gso_max_size", "pad", "xdp" ]

# Fields in struct rtnl_link_stats64 (if_link.h)
_stat_struct = [ "rx_packets", "tx_packets", "rx_bytes", "tx_bytes",
                 "rx_errors", "tx_errors", "rx_dropped", "tx_dropped",
                 "multicast", "collisions", "rx_length_errors",
                 "rx_over_errors", "rx_crc_errors", "rx_frame_errors",
                 "rx_fifo_errors", "rx_missed_errors", "tx_aborted_errors",
                 "tx_carrier_errors", "tx_fifo_errors", "tx_heartbeat_errors",
                 "tx_window_errors", "rx_compressed", "tx_compressed",
                 "rx_nohandler" ]

# Fields in struct ifaddrmsg, minus the "ifa_" (if_addr.h)
_ifaddrmsg_struct = [ "family", "prefixlen", "flags", "scope", "index" ]

# Lowercase versions of IFA_XXX enums, minus the "IFA_" (if_addr.h)
ifa_enum = [ "unspec", "address", "local", "label", "broadcast",
             "anycast", "cacheinfo", "multicast", "flags" ]

# returned for LINK events
class linkevent():
    def __init__(self, nlmsg, ifi, iff, ifla):
        self.nlmsg=nlmsg
        self.ifi=ifi
        self.iff=iff
        self.ifla=ifla

        # create some shortcut accessors
        self.ifname = ifla["ifname"]
        self.exists = nlmsg["type"]==16 # RTM_NEWLINK
        self.up = iff["up"]
        self.carrier = None if "carrier" not in ifla else bool(ifla["carrier"])

    def show(self, verbose=False):
        print("%s: exists=%s up=%s carrier=%s" % (self.ifname, self.exists, self.up, self.carrier))
        if verbose:
            print("    nlmsg     =", str(self.nlmsg))
            print("    ifi       =", str(self.ifi))
            print("    iff       =", str(self.iff))
            print("    ifla      =", str(self.ifla))

# returned for IPV4 events
class ipv4event():
    def __init__(self, nlmsg, ifaddrmsg, ifa):
        self.nlmsg = nlmsg
        self.ifaddrmsg = ifaddrmsg
        self.ifa = ifa

        self.ifname = self.label = ifa["label"]
        self.exists = nlmsg["type"] == 20 # RTM_NEWADDR
        self.prefix = self.prefixlen = ifaddrmsg["prefixlen"]
        self.address = ifa.get("address")

    def show(self, verbose=False):
        print("%s: exists=%s address=%s prefix=%d" % (self.ifname, self.exists, self.address, self.prefix))
        if verbose:
            print("    nlmsg     =", str(self.nlmsg))
            print("    ifaddrmsg =", str(self.ifaddrmsg))
            print("    ifa       =", str(self.ifa))

class netlink():

    # Open the netlink socket.
    # Mode defines what kind of event packets to be returned, must be LINK,
    # IPV4, or LINK|IPV4. Default is LINK.
    # Debug spews to stderr, higher numbers == more spew.
    def __init__(self, mode=LINK, debug=0):
        self.mode=mode
        if mode not in [LINK, IPV4, LINK|IPV4]: raise Exception("Must specify mode=LINK, mode=IPV4, or mode=LINK|IPV4")
        self.debug=debug

        self.sock=socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE)
        self.sock.bind((os.getpid(), self.mode))

    def _debug(self, *args, level=1):
        if self.debug >= level: print(args, file=sys.stderr )

    # process ifla attribute and return { name: value }, or None
    def _parse_ifla(self, nla_type, data):
        if nla_type >= len(ifla_enum):
            self._debug("Invalid IFLA nla_type", type)
            return None

        name = ifla_enum[nla_type]

        if name in ["address", "broadcast"]:
            # colon-separated hex octets
            return { name : ":".join(list("%02X" % c for c in list(bytearray(data)))) }

        if name in ["ifname", "ifalias", "qdisc"]:
            # NUL-terminated string
            return { name : data.split(b"\x00")[0].decode("ascii") }

        if name == "stats64":
            # rtnl_link_stats64 is 24 unsigned long longs (64-bit), call it "stats"
            return { "stats": dict(zip(_stat_struct, struct.unpack("=24Q", data))) }

        if name in ["phy_port_id", "phys_switch_id"]:
            # raw hex
            return { name : data.hex() }

        if len(data) == 1:
            # generic 8-bit data
            return { name : struct.unpack("B", data)[0] }

        if len(data) == 4:
            # generic 32-bit data
            return { name : struct.unpack("=L", data)[0] }

        self._debug("Don't know how to decode IFLA_%s" % name.upper(), level=2)

        return None

    # process ifa attribute and return { name: value } or None
    def _parse_ifa(self, nla_type, data):
        if nla_type >= len(ifa_enum):
            self._debug("Invalid IFA nla_type", type)
            return None

        name = ifa_enum[nla_type]

        if name in ["address", "local", "broadcast", "anycast", "multicast" ]:
            # dot-separated decimal octets
            return { name : ".".join(list("%d" % c for c in list(bytearray(data)))) }

        if name == "label":
            # NUL-terminated string
            return { name : data.split(b"\x00")[0].decode("ascii") }

        if len(data) == 1:
            # generic 8-bit data
            return { name : struct.unpack("B", data)[0] }

        if len(data) == 4:
            # generic 32-bit data
            return { name : struct.unpack("=L", data)[0] }

        self._debug("Don't know how to decode IFA_%s" % name.upper(), level=2)
        return None

    # process attribute data with specified parser and return dict
    def _attributes(self, data, parser):
        if len(data) <= 4: return None
        attrs={}
        while len(data) >= 4:

            # first 4 bytes is struct nlattr (netlink.h) then attribute data depending on nla_len
            nla_len, nla_type = struct.unpack("=HH", data[:4])
            self._debug("nla_len=%d, nla_type=%d" % (nla_len, nla_type), level=2)
            if (nla_len < 4): break # done!
            if nla_len > len(data):
                self._debug("Only %d bytes of remaining data!" % len(data))
                return None

            attr = parser(nla_type, data[4:nla_len])
            if attr: attrs.update(attr)

            # skip to next attribute, note we pad nla_len to multiple of 4
            data = data[((nla_len+3) & ~3):]
        return attrs


    # Wait for a netlink event.  Note this is an iterator, use with "for".  If
    # timeout (seconds) is specified, exits if no event reported within that
    # time (raises StopIteration). If strict is set, do not return events that
    # don't specify carrier state or ip address. Accept and reject are lists of
    # globs, only interfaces that match an accept glob and do not match a
    # reject glob will be returned, by default returns everything.
    def wait(self, timeout=None, strict=True, accept=['*'], reject=[]):
        expire = 0
        while True:
            if timeout is not None:
                if not expire: expire = time.monotonic() + timeout
                s = select.select([self.sock],[],[], max(0, expire-time.monotonic()))
                if not s[0]: return
            data = self.sock.recv(65535)
            self._debug("Netlink packet is %d bytes" % len(data))

            while len(data) >= 16:
                # first 16 bytes is struct nlmsghdr (netlink.h)
                nlmsg = dict(zip(_nlmsg_struct, struct.unpack("=LHHLL", data[0:16])))
                self._debug("nlmsg =", nlmsg)
                if nlmsg["len"] > len(data): break

                if nlmsg["type"] == 3: return  # NLMSG_DONE, occurs at the end of a dump (netlink.h)


                if len(data) >= 32 and nlmsg["type"] in [16,17]:  # RTM_NEWLINK or RTM_DELLINK (rtnetlink.h)
                    # next 16 bytes is ifinfomsg (rtnetlink.h)
                    ifi = dict(zip(_ifi_struct, struct.unpack("=BxHlLL",data[16:32])))
                    self._debug("ifi =", ifi)
                    # parse interface flags to iff
                    iff={}
                    for b,v in enumerate(_iff_bits): iff[v]=bool(ifi["flags"] & (1 << b))
                    self._debug("iff =", iff)

                    # process the rest of the packet for netlink attributes
                    ifla = self._attributes(data[32 : nlmsg["len"]], self._parse_ifla)
                    if ifla:
                        self._debug("ifla =", ifla)
                        ifname=ifla.get("ifname")
                        if not ifname:
                            self._debug("Dropping linkevent without ifname")
                        elif strict and "carrier" not in ifla:
                            self._debug("Dropping linkevent without carrier")
                        elif matches(ifname, reject) or not matches(ifname, accept):
                            self._debug("Dropping linkevent from", ifname)
                        else:
                            yield linkevent(nlmsg, ifi, iff, ifla)  # yield linkevent
                            expire = 0                              # restart the timeout

                elif len(data) >= 24 and nlmsg["type"] in [20, 21]: # RTM_NEWADDR or RTM_DELADDR (rtnetlink.h)
                    # first 8 bytes if struct ifaddrmsg
                    ifaddrmsg = dict(zip(_ifaddrmsg_struct, struct.unpack("=BBBBL", data[16:24])))
                    self._debug("ifaddrmsg =", ifaddrmsg)
                    ifa = self._attributes(data[24: nlmsg["len"]], self._parse_ifa)
                    if ifa:
                        self._debug("ifa =", ifa)
                        ifname=ifa.get("label")
                        if not ifname:
                            self._debug("Dropping addrevent without ifname")
                        elif strict and "address" not in ifa:
                            self._debug("Dropping addrevent without address")
                        elif matches(ifname, reject) or not matches(ifname, accept):
                            self._debug("Dropping addrevent from", ifname)
                        else:
                            yield ipv4event(nlmsg, ifaddrmsg, ifa)  # yield ipv4event
                            expire = 0                              # restart the timeout

                # advance to next packet, if any
                data = data[nlmsg["len"]:]

    # Issue netlink dump command and yield all matching interfaces, then exit
    # Mode is LINK or IPV4 but only needs to be specified when object was created with support for both.
    def dump(self, mode=None, accept=['*'], reject=[]):
        if mode is None: mode=self.mode
        if mode not in [LINK, IPV4]: raise Exception("Must specify mode=LINK or mode=IPV4")
        if not mode & self.mode: raise Exception("Netlink not configured for specified mode")

        data = struct.pack("=LHHLLL",
            20,                         # nlmsg_len = total length of packet
            18 if mode==LINK else 22,   # nlmsg_type = RTM_GETLINK or RTM GETADDR
            0x0301,                     # nlmsg_flags = NLM_F_ROOT|NLM_F_MATCH|NLM_F_REQUEST
            1,                          # nlmsg_seq
            os.getpid(),                # nlmsg_pid
            17                          # rtgen_familiy = AF_PACKET
        )
        self.sock.send(data)
        return self.wait(timeout=1, accept=accept, reject=reject)

if __name__ == "__main__":
    nl=netlink(mode=LINK|IPV4)  # create the netlink object

    print("Current configuration:\n")
    for e in nl.dump(mode=LINK):
        e.show(verbose=True)
        print()
    for e in nl.dump(mode=IPV4):
        e.show(verbose=True)
        print()

    print("Waiting for events...\n")
    while True:
        # Return interface events except from lo, timeout every 5 seconds
        active=False
        for e in nl.wait(timeout=5, strict=False, reject=['lo']):
            e.show(verbose=True)
            print()
            active=True
        # timeout
        if active:
            print("Timeout\n")
