from __future__ import print_function
import os, struct, socket, time, select

# python2 doesn't support monotonic time, just use the wall clock
if 'monotonic' not in dir(time): time.monotonic=time.time

class rtnetlink():
    # These are the nlmsg_xxx symbols from netlink.h, minus the "nlmsg_"
    _nlmsg = [ "len", "type", "flags", "seq", "pid" ]

    # These are the ifi_xxx symbols from rtnetlink.h, minus the "ifi_"
    _ifi = [ "family", "type", "index", "flags", "changes" ]

    # These are lowercase versions if IFLA_XXX symbols from if_link.h, minus
    # the "IFLA_"
    _ifla = [ "none", "address", "broadcast", "ifname", "mtu", "link",
              "qdisc", "stats", "cost", "priority", "master", "wireless",
              "protinfo", "txqlen", "map", "weight", "operstate", "linkmode",
              "linkinfo", "net_ns_pid", "ifalias", "num_vf", "vfinfo_list",
              "stats64", "vf_ports", "port_self", "af_spec", "group",
              "net_ns_fd", "ext_mask", "promiscuity", "num_tx_queues",
              "num_rx_queues", "carrier", "phys_port_id", "carrier_changes",
              "phys_switch_id", "link_netnsid", "phys_port_name", "proto_down",
              "gso_max_segs", "gso_max_size", "pad", "xdp" ]

    # These are the names of the fields in struct
    # rtnl_link_stats/rtnl_link_stats64, from if_link.h
    _stat = [ "rx_packets", "tx_packets", "rx_bytes", "tx_bytes", "rx_errors",
              "tx_errors", "rx_dropped", "tx_dropped", "multicast",
              "collisions", "rx_length_errors", "rx_over_errors",
              "rx_crc_errors", "rx_frame_errors", "rx_fifo_errors",
              "rx_missed_errors", "tx_aborted_errors", "tx_carrier_errors",
              "tx_fifo_errors", "tx_heartbeat_errors", "tx_window_errors",
              "rx_compressed", "tx_compressed", "rx_nohandler" ]

    # Open the netlink socket
    def __init__(self, debug=False):
        self.debug=debug
        self.sock=socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, socket.NETLINK_ROUTE)
        self.sock.bind((os.getpid(),1)) # RTMGRP_LINK messages

    # Return netlink event, or None after timeout, if specified
    def event(self, timeout=None):
        if timeout: timeout += time.monotonic()
        while True:
            s = select.select([self.sock],[],[], timeout-time.monotonic() if timeout else None)
            if not s[0]: return None
            data = self.sock.recv(65535)
            if self.debug: print("Packet = %d bytes" % len(data))
            if len(data) < 16: continue

            event={}

            # first 16 bytes is struct nlmsghdr, from netlink.h
            event["nlmsg"]=dict(zip(self._nlmsg,struct.unpack("=LHHLL", data[:16])))
            if self.debug: print("nlmsg =",event["nlmsg"])
            if event["nlmsg"]["len"] != len(data): continue
            data = data[16:]

            # nlmsg_types from rtnetlink.h
            if event["nlmsg"]["type"] == 16: event["attached"]=True
            elif event["nlmsg"]["type"] == 17: event["attached"]=False
            else:
                if self.debug: print("Unknown nlmsg type")
                continue
            if self.debug: print(event["event"])

            # next 16 bytes is ifinfomsg, from rtnetlink.h
            if len(data) < 16: continue
            event["ifi"]=dict(zip(self._ifi, struct.unpack("=BxHlLL",data[:16])))
            if self.debug: print("ifi =",event["ifi"])
            data=data[16:]

            event["ifla"]={}
            while len(data) >= 4:
                # next 4 bytes is struct nlattr, from netlink.h
                nla_len, nla_type = struct.unpack("=HH", data[:4])
                name = self._ifla[nla_type] if nla_type < len(self._ifla) else None

                if self.debug: print("nla_len=%d, nla_type=%d (%s)" % (nla_len, nla_type, "IFLA_"+name.upper() if name else "unknown"))
                if (nla_len < 4): break
                if nla_len > len(data):
                    if self.debug: print("Only %d bytes of remaining data!" % len(data))
                    event=None
                    break

                if name:
                    name = self._ifla[nla_type]
                    value = None
                    if name in ["address", "broadcast"]:
                        # colon-seperated octets
                        value = ":".join(list("%02X" % c for c in list(data[4:nla_len])))
                    elif name in ["ifname", "ifalias"]:
                        # 0-terminated string
                        value = data[4:nla_len].split(b"\x00")[0].decode("ascii")
                    elif name is "stats":
                        # struct rtnl_link_stats (from if_link.h)
                        if event["ifla"]["stats"]:
                            # don't overwrite existing stats
                            name = None
                        else:
                            value=dict(zip(self._stat, struct.unpack("=24L", data[4:nla_len])))
                    elif name is "stats64":
                        # data is struct rtnl_link_stats64, same as stats but with 64-bit counters
                        # overwrite existing "stats"
                        name = "stats"
                        value=dict(zip(self._stat, struct.unpack("=24Q", data[4:nla_len])))
                    elif name in ["phy_port_id", "phys_switch_id"]:
                        # data is raw hex
                        value = data[4:nla_len].hex()

                    if name is not None:
                        if value is None:
                            if nla_len == 5: value=struct.unpack("B", data[4:5])[0]
                            elif nla_len == 8: value=struct.unpack("=L", data[4:8])[0]

                        if value is not None:
                            event["ifla"][name]=value

                # skip over the attribute, but pad length to multiple of 4
                data = data[((nla_len+3) & ~3):]

            if (event):
                if self.debug: print("ifla =", event["ifla"])
                return event

if __name__ == "__main__":
    import pprint;
    nl=rtnetlink()
    while True: pprint.pprint(nl.event(10))
