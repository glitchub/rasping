#!/bin/bash -eu

# Rasping install 
# See also rasping.conf

die() { echo $* >&2; exit 1; }

grep -q "Raspberry Pi reference 2019-06-20" /etc/rpi-issue || die "This script requires 2019-06-20-raspbin-buster-lite.img"
((!UID)) || die "You must be root!"

here=${0%/*}

# load configuration
[[ -f $here/rasping.conf ]] || die "Can't find rasping.conf"
source $here/rasping.conf

# install packages
DEBIAN_FRONTEND=noninteractive apt -y install iptables-persistent dnsmasq

echo "Updating dhcpcd.conf"
# first delete old mods
sed -i "/rasping start/,/rasping end/d" /etc/dhcpcd.conf
# then append new
{
    echo "# rasping start"
    echo allowinterfaces eth0 eth1
    echo ipv4only
    echo noipv4ll
    echo noalias
    echo interface eth1
    echo static ip_address=$lan_ip
    echo nolink
    if [[ ${wan_ip:+x} ]]; then
        # configure eth1 static ip
        echo interface eth0
        echo static ip_address=$wan_ip
        echo static routers=$wan_gateway
        echo static domain_name_server=$wan_dns
        echo nolink
    fi
    echo "# rasping end"
} >> /etc/dhcpcd.conf    

echo "Installing files"
for f in $(find $here/overlay -type f,l -printf "%P\n"); do 
    mkdir -p /${f%/*}
    cp -v -P $here/overlay/$f /$f
done

# fix dnsmasq dhcp range
if [[ ${dhcp_range:+x} ]]; then
    sed -i "s/# *dhcp-range=.*/dhcp-range=$dhcp_range/" /etc/dnsmasq.d/rasping.conf
fi    

echo "Configuring iptables"
iptables -F 
iptables -F -tnat

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -i eth1 -j ACCEPT
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
# process forward() array, each element has form port:destip:destport
if [[ ${forward:+x} ]]; then
    for p in ${forward[@]}; do 
        iptables -t nat -A PREROUTING -i eth0 -p tcp --dport ${p%%:*} -j DNAT --to ${p#*:}
    done
fi    
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -P INPUT DROP

# also drop all IPv6
ip6tables -F 
ip6tables -P INPUT DROP

# save config
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6

echo "Done!"
