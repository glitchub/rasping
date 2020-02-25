from __future__ import print_function
import os, struct, socket, time, select, fnmatch
# receive network interface status via netlink

# python2 doesn't support monotonic time, use the wall clock for timeouts
if 'monotonic' not in dir(time): time.monotonic=time.time

# return true if string s matches any listed glob
def matches(s, globs):
    for g in globs:
        if fnmatch.fnmatch(s, g):
            return True
    return False

# returned by netlink.dump or netlink.wait, this just a container for the interface data
class event():
    def __init__(self, nlmsg, ifi, iff, ifla):
        self.nlmsg=nlmsg
        self.ifi=ifi
        self.iff=iff
        self.ifla=ifla

        # create some shortcut accessors
        self.ifname = ifla["ifname"]
        self.attached = nlmsg["type"]==16 # RTM_NEWLINK
        self.up = iff["up"]
        self.carrier = None if "carrier" not in ifla else bool(ifla["carrier"])

class netlink():
    # nlmsg_xxx symbols from netlink.h, minus the "nlmsg_"
    _nlmsg_fields = [ "len", "type", "flags", "seq", "pid" ]

    # ifi_xxx symbols from rtnetlink.h, minus the "ifi_"
    _ifi_fields = [ "family", "type", "index", "flags", "changes" ]

    # Lowercase versions of IFLA_XXX symbols from if_link.h, minus the "IFLA_"
    _ifla_fields = [ "none", "address", "broadcast", "ifname", "mtu", "link",
                     "qdisc", "stats", "cost", "priority", "master",
                     "wireless", "protinfo", "txqlen", "map", "weight",
                     "operstate", "linkmode", "linkinfo", "net_ns_pid",
                     "ifalias", "num_vf", "vfinfo_list", "stats64", "vf_ports",
                     "port_self", "af_spec", "group", "net_ns_fd", "ext_mask",
                     "promiscuity", "num_tx_queues", "num_rx_queues",
                     "carrier", "phys_port_id", "carrier_changes",
                     "phys_switch_id", "link_netnsid", "phys_port_name",
                     "proto_down", "gso_max_segs", "gso_max_size", "pad", "xdp" ]

    # Fields in struct rtnl_link_stats or rtnl_link_stats64 (if_link.h)
    _stat_fields = [ "rx_packets", "tx_packets", "rx_bytes", "tx_bytes",
                     "rx_errors", "tx_errors", "rx_dropped", "tx_dropped",
                     "multicast", "collisions", "rx_length_errors",
                     "rx_over_errors", "rx_crc_errors", "rx_frame_errors",
                     "rx_fifo_errors", "rx_missed_errors", "tx_aborted_errors",
                     "tx_carrier_errors", "tx_fifo_errors",
                     "tx_heartbeat_errors", "tx_window_errors",
                     "rx_compressed", "tx_compressed", "rx_nohandler" ]

    # Bits in ifi_flags, in order starting with LSB
    _iff_bits = [ "up", "broadcast", "debug", "loopback", "pointopoint",
                  "notrailers", "running", "noarp", "promisc", "allmulti",
                  "master", "slave", "multicast", "portsel", "automedia",
                  "dynamic", "lower_up", "dormant", "echo" ]

    # Open the netlink socket, debug flag spews stuff to stdout
    # If dump is set, request status for all existing interfaces
    def __init__(self, debug=False):
        self.debug=debug
        self.sock=socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE)
        self.sock.bind((os.getpid(),1)) # RTMGRP_LINK messages

    # process data as netlink attributes and return ifla dict, or None
    def _attributes(self, data):
        if len(data) <= 4: return None
        ifla={}
        while len(data) >= 4:
            # first 4 bytes is struct nlattr (netlink.h) then attribute data depending on nla_len
            nla_len, nla_type = struct.unpack("=HH", data[:4])
            if self.debug: print("nla_len=%d, nla_type=%d" % (nla_len, nla_type))
            if (nla_len < 4): break # done!
            if nla_len > len(data):
                if self.debug: print("Only %d bytes of remaining data!" % len(data))
                return None

            if nla_type < len(self._ifla_fields):
                field = self._ifla_fields[nla_type]

                if field in ["address", "broadcast"]:
                    # colon-separated octets
                    ifla[field] = ":".join(list("%02X" % c for c in list(bytearray(data[4:nla_len]))))
                elif field in ["ifname", "ifalias"]:
                    # NUL-terminated string
                    ifla[field] = data[4:nla_len].split(b"\x00")[0].decode("ascii")
                elif field is "stats":
                    # struct rtnl_link_stats, 24 unsigned ints
                    # don't overwrite existing "stats"
                    if not ifla.get("stats"): ifla["stats"]=dict(zip(self._stat_fields, struct.unpack("=24L", data[4:nla_len])))
                elif field is "stats64":
                    # struct rtnl_link_stats64, same fields fields as stats but 24 unsigned long longs (64-bit),
                    # always overwrite existing "stats"
                    ifla["stats"] = dict(zip(self._stat_fields, struct.unpack("=24Q", data[4:nla_len])))
                elif field in ["phy_port_id", "phys_switch_id"]:
                    # raw hex
                    ifla[field] = data[4:nla_len].hex()
                elif nla_len == 5:
                    # generic 8-bit data
                    ifla[field]=struct.unpack("B", data[4:5])[0]
                elif nla_len == 8:
                    # generic 32-bit data
                    ifla[field]=struct.unpack("=L", data[4:8])[0]
                elif self.debug:
                    print("Don't know how to decode IFLA_%s" % field.upper())

            # skip to next attribute, note we pad nla_len to multiple of 4
            data = data[((nla_len+3) & ~3):]

        return ifla

    # Wait for a netlink event.  Note this is an iterator, use with "for".  If
    # timeout (seconds) is specified, exits if no event reported within that
    # time (raises StopIteration). If strict is set, do not return events that
    # don't specify carrier state. Accept and reject are lists of globs, only
    # interfaces that match an accept glob and do not match a reject glob will
    # be returned, by default returns everything.
    def wait(self, timeout=None, strict=True, accept=['*'], reject=[]):
        expire = 0
        while True:
            if timeout is not None:
                if not expire: expire = time.monotonic() + timeout
                s = select.select([self.sock],[],[], max(0, expire-time.monotonic()))
                if not s[0]: return
            data = self.sock.recv(65535)
            if self.debug: print("Netlink packet is %d bytes" % len(data))

            while len(data) >= 16:
                # first 16 bytes is struct nlmsghdr (netlink.h)
                nlmsg = dict(zip(self._nlmsg_fields, struct.unpack("=LHHLL", data[0:16])))
                if self.debug: print("nlmsg =", nlmsg)
                if nlmsg["len"] > len(data): break

                if nlmsg["type"] == 3: return  # NLMSG_DONE, occurs at the end of a dump (netlink.h)

                if len(data) >= 32 and nlmsg["type"] in [16,17]:  # RTM_NEWLINK or RTM_DELLINK (rtnetlink.h)
                    # next 16 bytes is ifinfomsg (rtnetlink.h)
                    ifi = dict(zip(self._ifi_fields, struct.unpack("=BxHlLL",data[16:32])))
                    if self.debug: print("ifi =", ifi)
                    # parse interface flags to iff
                    iff={}
                    for b,v in enumerate(self._iff_bits): iff[v]=bool(ifi["flags"] & (1 << b))
                    if self.debug: print("iff =", iff)

                    # process the rest of the packet for netlink attributes
                    ifla = self._attributes(data[32 : nlmsg["len"]])
                    if ifla:
                        if self.debug: print("ifla =", ifla)
                        ifname=ifla.get("ifname")
                        if not ifname:
                            if self.debug: print("Dropping event without ifname")
                        elif strict and "carrier" not in ifla:
                            if self.debug: print("Dropping event without carrier")
                        elif matches(ifname, reject) or not matches(ifname, accept):
                            if self.debug: print("Dropping event from", ifname)
                        else:
                            yield event(nlmsg, ifi, iff, ifla)  # yield an event
                            expire = 0                          # restart the timeout

                # advance to next packet, if any
                data = data[nlmsg["len"]:]

    # Issue netlink dump command and yield all matching interfaces, then exit
    def dump(self, accept=['*'], reject=[]):
        data = struct.pack("=LHHLLL",
            20,             # nlmsg_len = total length of packet
            18,             # nlmsg_type = RTM_GETLINK
            0x0301,         # nlmsg_flags = NLM_F_ROOT|NLM_F_MATCH|NLM_F_REQUEST
            1,              # nlmsg_seq
            os.getpid(),    # nlmsg_pid
            17              # rtgen_familiy = AF_PACKET
        )
        self.sock.send(data)
        return self.wait(timeout=1, accept=accept, reject=reject)

if __name__ == "__main__":
    nl=netlink()   # create the netlink object

    print("Current interfaces:\n")
    for e in nl.dump():
        print("    %s: attached=%s up=%s carrier=%s" % (e.ifname, e.attached, e.up, e.carrier))

    print("\nWaiting for events...\n")
    while True:
        # Return interface events except from lo, timeout after 5 seconds
        active=False
        for e in nl.wait(timeout=5, reject=['lo']):
            print("nlmsg =", str(e.nlmsg))
            print("ifi   =", str(e.ifi))
            print("iff   =", str(e.iff))
            print("ifla  =", str(e.ifla))
            print("%s: attached=%s up=%s carrier=%s\n" % (e.ifname, e.attached, e.up, e.carrier))
            active=True
        # timeout
        if active:
            print("Timeout\n")
