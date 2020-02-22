from __future__ import print_function
import os, struct, socket, time, select, fnmatch

# python2 doesn't support monotonic time, just use the wall clock
if 'monotonic' not in dir(time): time.monotonic=time.time

class rtnetlink():
    # The nlmsg_xxx symbols from netlink.h, minus the "nlmsg_"
    _nlmsg_fields = [ "len", "type", "flags", "seq", "pid" ]

    # The ifi_xxx symbols from rtnetlink.h, minus the "ifi_"
    _ifi_fields = [ "family", "type", "index", "flags", "changes" ]

    # Lowercase versions if IFLA_XXX symbols from if_link.h, minus the "IFLA_"
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

    # Open the netlink socket
    def __init__(self, accept=['*'], reject=['lo'], debug=False):
        self.accept=accept
        self.reject=reject
        self.debug=debug
        self.sock=socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE)
        self.sock.bind((os.getpid(),1)) # RTMGRP_LINK messages

    # return true if string s matches any listed glob
    def _matches(self, s, globs):
        for g in globs:
            if fnmatch.fnmatch(s, g):
                return True
        return False

    # send a dump command
    def dump(self):
        data = struct.pack("=LHHLLL",
            20,             # nlmsg_len = total length of packet
            18,             # nlmsg_type = RTM_GETLINK
            0x0301,         # nlmsg_flags = NLM_F_ROOT|NLM_F_MATCH|NLM_F_REQUEST
            1,              # nlmsg_seq
            os.getpid(),    # nlmsg_pid
            17              # rtgen_familiy = AF_PACKET
        )
        self.sock.send(data)

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
                    ifla[field] = ":".join(list("%02X" % c for c in list(bytearray(data[4:nla_len])))) # colon-separated octets
                elif field is "ifname":
                    ifname = data[4:nla_len].split(b"\x00")[0].decode("ascii") # 0-terminated string
                    # filter unwanted interfaces
                    if self._matches(ifname, self.reject) or not self._matches(ifname, self.accept):
                        if self.debug: print("Dropping event from", ifname)
                        return None
                    ifla["ifname"] = ifname
                elif field is "ifalias":
                    ifla[field] = data[4:nla_len].split(b"\x00")[0].decode("ascii") # 0-terminated string
                elif field is "stats":
                    # struct rtnl_link_stats, 24 unsigned ints
                    # don't overwrite existing "stats"
                    if not ifla.get("stats"): ifla["stats"]=dict(zip(self._stat_fields, struct.unpack("=24L", data[4:nla_len])))
                elif field is "stats64":
                    # struct rtnl_link_stats64, same fields fields as stats but 24 unsigned long longs (64-bit),
                    # always overwrite existing "stats"
                    ifla["stats"] = dict(zip(self._stat_fields, struct.unpack("=24Q", data[4:nla_len])))
                elif field in ["phy_port_id", "phys_switch_id"]:
                    # data is raw hex
                    ifla[field] = data[4:nla_len].hex()
                elif nla_len == 5:
                    # generic 8-bit data
                    ifla[field]=struct.unpack("B", data[4:5])[0]
                elif nla_len == 8:
                    # generic 32-bit data
                    ifla[field]=struct.unpack("=L", data[4:8])[0]

            # skip to next attribute, note we pad nla_len to multiple of 4
            data = data[((nla_len+3) & ~3):]

        return ifla

    # read a netlink event. Returns None after timeout, if specified, or after a dump is complete.
    # this is a generator
    def read(self, timeout=None):
        if timeout: timeout += time.monotonic()
        while True:
            s = select.select([self.sock],[],[], timeout-time.monotonic() if timeout else None)
            if not s[0]: return
            data = self.sock.recv(65535)
            if self.debug: print("Packet = %d bytes" % len(data))

            while len(data) >= 16:
                # first 16 bytes is struct nlmsghdr, from netlink.h
                nlmsg=dict(zip(self._nlmsg_fields, struct.unpack("=LHHLL", data[0:16])))
                if self.debug: print("nlmsg =", nlmsg)
                if nlmsg["len"] > len(data): break

                if nlmsg["type"] == 3: yield {}                     # NLMSG_DONE from netlink.h
                elif len(data) >= 32 and nlmsg["type"] in [16,17]:  # RTM_NEWLINK or RTM_DELLINK from rtnetlink.h
                    # next 16 bytes is ifinfomsg, from rtnetlink.h
                    ifi=dict(zip(self._ifi_fields, struct.unpack("=BxHlLL",data[16:32])))
                    if self.debug: print("ifi =", ifi)

                    # process the rest of the packet for netlink attributes
                    ifla = self._attributes(data[32 : nlmsg["len"]])
                    if ifla:
                        if self.debug: print("ifla =", ifla)
                        # return dict of dicts
                        yield {"attached":nlmsg["type"]==16, "nlmsg":nlmsg, "ifi":ifi, "ifla":ifla}

                # advance to next packet, if any
                data = data[nlmsg["len"]:]

if __name__ == "__main__":
    import pprint;
    nl=rtnetlink(debug=1)
    cr=False
    prior=None
    repeat=0

    nl.dump() # initially dump all interfaces
    while True:
        for e in nl.read(1):
            this=pprint.pformat(e, width=1)
            if this == prior:
                repeat += 1
                print("Repeat",repeat)
            else:
                print(this)
                prior = this
                repeat = 0
            cr=True
        if cr:
            print("")
            cr=False
