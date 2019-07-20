# Raspberry PI NAT Gateway

#### USER CONFIGURATION

# The built in ethernet connects to the WAN. To give it a static IP, define the
# IP address, gateway, and DNS server. Otherwise comment these out to use DHCP.
# WAN_IP = 172.16.128.240/24
# WAN_GW = 172.16.128.1
# WAN_DNS = 8.8.8.8

# The USB ethernet is the gateware for the LAN, it always has a static IP.
LAN_IP = 192.168.111.1

# Define a range of IP addresses to assign via DHCP on the LAN, or comment this
# out if all LAN devices use static IP.
DHCP_RANGE = 192.168.111.128,192.168.111.254

# Define TCP ports to allow on the WAN interface, or comment out to block all
# ports. (Default is to allow ssh)
UNBLOCK = 22

# Define TCP ports to be forwarded from WAN to devices on the LAN, each in the
# form "WAN_PORT=LAN_IP:LAN_PORT", or comment this out if no ports should be
# forwarded.
# Note WAN ports 32768 to 60999 are reserved by the kernel, these should be
# avoided (cat /proc/sys/net/ipv4/ip_local_port_range).
# FORWARD = 2210=192.168.111.10:22 2211=192.168.111.11:22

# These params can also be passed on the make command line, eg: 
#
#    make LAN_IP=1.2.3.4 UNBLOCK=

#### END USER CONFIGURATION

# Make sure we're running the right code and are not root
ifeq ($(shell grep "Raspberry Pi reference 2019-06-20" /etc/rpi-issue),)
$(error "Requires Raspberry Pi running 2019-06-20-raspbin-buster-lite.img")
endif

ifneq ($(filter root,${USER}),)
$(error Must not be run as root))
endif

# package to install
PACKAGES=iptables-persistent dnsmasq

# files to copy from overlay to the root
OVERLAY=$(shell find overlay -type f,l -printf "%P ")

# files to generate
GENERATE=/etc/iptables/rules.v4 /etc/iptables/rules.v6 /etc/dhcpcd.conf

# recreate everything
.PHONY: default PACKAGES ${OVERLAY} ${GENERATE}

.PHONY: default
default: PACKAGES ${OVERLAY} ${GENERATE}

ifndef CLEAN
# Install NEW files from overlay to root
${OVERLAY}: PACKAGES
	sudo mkdir -p /$(dir $@)
	sudo cp -vP overlay/$@ /$@
ifdef DHCP_RANGE
	$(if $(filter etc/dnsmasq.d/rasping.conf,$@),echo "dhcp-range=${DHCP_RANGE}" | sudo bash -c 'cat >> /$@')
endif        
else
# Delete overlay files
${OVERLAY}:
	sudo rm -f /$@
endif        

ifndef CLEAN
# Install packages
PACKAGES:
	DEBIAN_FRONTEND=noninteractive sudo -E apt install -y ${PACKAGES}
else      
# Remove packages
PACKAGES: ${OVERLAY}
	DEBIAN_FRONTEND=noninteractive sudo -E apt remove --autoremove --purge -y ${PACKAGES}
endif        

# configure NAT, block everything on the WAN except as defined by UNBLOCK or FORWARD
/etc/iptables/rules.v4: PACKAGES
	sudo iptables -F
	sudo iptables -F -tnat
ifndef CLEAN        
	sudo iptables -P INPUT DROP
	sudo iptables -A INPUT -i lo -j ACCEPT
	sudo iptables -A INPUT -i eth1 -j ACCEPT
	sudo iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
	sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
ifdef UNBLOCK
	for p in ${UNBLOCK}; do sudo iptables -A INPUT -p tcp --dport $$p -j ACCEPT; done
endif     
ifdef FORWARD
	for p in ${FORWARD}; do sudo iptables -t nat -A PREROUTING -i eth0 -p tcp --dport $${p%=*} -j DNAT --to $${p#*=}; done
endif
	sudo iptables-save -f $@
endif

# drop any IPv6 (it's also entirely turned off by sysctl)
/etc/iptables/rules.v6: PACKAGES
	sudo ip6tables -F
ifndef CLEAN        
	sudo ip6tables -P INPUT DROP
	sudo ip6tables -P FORWARD DROP
	sudo ip6tables-save -f $@
endif        

# dhcpcd gives static IP to eth1, and possibly to eth0
/etc/dhcpcd.conf:
	sudo sed -i '/rasping start/,/rasping end/d' $@ # first delete the old
ifndef CLEAN        
	printf "\
# rasping start\n\
allowinterfaces eth0 eth1\n\
ipv4only\n\
noipv4ll\n\
noalias\n\
interface eth1\n\
static ip_address=${LAN_IP}\n\
nolink\n\
" | sudo bash -c 'cat >> $@'
ifdef WAN_IP
	printf "\
# rasping start\n\
interface eth0\n\
static ip_address=${WAN_IP}\n\
static routers=${WAN_GW}\n\
static domain_name_server=${WAN_DNS}\n\
nolink\n\
# rasping end\n\
" | sudo bash -c 'cat >> $@'
endif
endif

.PHONY: clean
clean:;make CLEAN=1
