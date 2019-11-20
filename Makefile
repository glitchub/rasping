# Raspberry PI NAT Gateway

# Make sure we're running the right code
ifeq ($(shell [ -f /etc/rpi-issue ] && [ $$(systemd --version | awk '{print $$2;exit}') -ge 241 ] && echo yes),)
$(error Requires Raspberry Pi with systemd version 241 or later)
endif

ifneq (${USER},root)
# become root if not already
default ${MAKECMDGOALS}:; sudo -E ${MAKE} ${MAKECMDGOALS}
else

include rasping.cfg
LAN_IP:=$(strip ${LAN_IP})
DHCP_RANGE:=$(strip ${DHCP_RANGE})
UNBLOCK:=$(strip ${UNBLOCK})
FORWARD:=$(strip ${FORWARD})
LAN_SSID:=$(strip ${LAN_SSID})
LAN_PASSPHRASE:=$(strip ${LAN_PASSPHRASE})
LAN_CHANNEL:=$(strip ${LAN_CHANNEL})
WAN_IP:=$(strip ${WAN_IP})
WAN_GW:=$(strip ${WAN_GW})
WAN_DNS:=$(strip ${WAN_DNS})

ifndef LAN_IP
$(error Must specify LAN_IP)
endif

# package to install
PACKAGES=iptables-persistent dnsmasq $(if $(strip ${LAN_SSID}),hostapd)

# files to generate or alter
FILES += /etc/default/hostapd
FILES += /etc/hostapd/rasping.conf
FILES  = /etc/iptables/rules.v4
FILES += /etc/iptables/rules.v6
FILES += /etc/dhcpcd.conf
FILES += /etc/dnsmasq.d/rasping.conf
FILES += /etc/issue.d/rasping.issue
FILES += /etc/sysctl.d/rasping.conf
FILES += /etc/systemd/network/rasping-br0.network
FILES += /etc/systemd/network/rasping-bridged.network
FILES += /etc/systemd/network/rasping-bridge.netdev

# recreate everything
.PHONY: install PACKAGES ${FILES}

ifndef CLEAN
install: PACKAGES ${FILES}
	systemctl enable systemd-networkd
	systemctl disable wpa_supplicant
ifdef LAN_SSID
	systemctl unmask hostapd
	systemctl enable hostapd
endif
	@echo "INSTALL COMPLETE"

# Install packages first
${FILES}: PACKAGES
PACKAGES:
	DEBIAN_FRONTEND=noninteractive apt install -y ${PACKAGES}
else
install: PACKAGES ${FILES}
	# delete downrev files
	rm -f /etc/issue.d/rasping*
	rm -f /etc/systemd/network/rasping*
	echo "UNINSTALL COMPLETE"

PACKAGES: ${FILES}
ifeq (${CLEAN},2)
	DEBIAN_FRONTEND=noninteractive apt remove --autoremove --purge -y ${PACKAGES}
endif
endif

# configure NAT, block everything on the WAN except as defined by UNBLOCK or FORWARD
/etc/iptables/rules.v4:
	iptables -F
	iptables -P INPUT ACCEPT
	iptables -F -tnat
ifndef CLEAN
	iptables -P INPUT DROP
	iptables -A INPUT ! -i eth0 -j ACCEPT
	iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
	iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
ifdef UNBLOCK
	for p in ${UNBLOCK}; do iptables -A INPUT -p tcp --dport $$p -j ACCEPT; done
endif
ifdef FORWARD
	# forward incoming and localhost
	for p in ${FORWARD}; do \
	    iptables -t nat -A PREROUTING -p tcp --dport $${p%=*} -j DNAT --to $${p#*=}; \
	    iptables -t nat -A OUTPUT -o lo -p tcp --dport $${p%=*} -j DNAT --to $${p#*=}; \
	done
endif
	iptables-save -f $@
endif

# drop any IPv6 (it's also entirely turned off by sysctl)
/etc/iptables/rules.v6:
	ip6tables -F
ifndef CLEAN
	ip6tables -P INPUT DROP
	ip6tables -P FORWARD DROP
	ip6tables-save -f $@
endif

# append dhcpcd.conf to set eth0 address, static if WAN_IP is defined
/etc/dhcpcd.conf:
	sed -i '/rasping start/,/rasping end/d' $@
ifndef CLEAN
	echo '# rasping start' >> $@
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'allowinterfaces eth0' >> $@
	echo 'ipv4only' >> $@
	echo 'noipv4ll' >> $@
	echo 'noalias' >> $@
	echo 'timeout=300' >> $@
ifdef WAN_IP
	echo 'interface eth0' >> $@
	echo 'static ip_address=${WAN_IP}' >> $@
	echo 'static routers=${WAN_GW}' >> $@
	echo 'static domain_name_server=${WAN_DNS}' >> $@
	echo 'nolink' >> $@
endif
	echo '# rasping end' >> $@
endif

# configure dnsmasq to serve on br0
/etc/dnsmasq.d/rasping.conf:
	rm -f $@
ifndef CLEAN
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'interface=br0' >> $@
	$(if $(strip ${DHCP_RANGE}),echo 'dhcp-range=${DHCP_RANGE}' >> $@)
endif

# enable hostapd (if LAN_SSID defined)
/etc/default/hostapd:
	sed -i '/rasping start/,/rasping end/d' $@
ifndef CLEAN
ifdef LAN_SSID
	echo '# rasping start' >> $@
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'DAEMON_CONF=/etc/hostapd/rasping.conf' >> $@
	echo '# rasping end' >> $@
endif
endif

# create hostapd config (if LAN_SSID is defined)
/etc/hostapd/rasping.conf:
	rm -f $@
ifndef CLEAN
ifdef LAN_SSID
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'interface=wlan0' >> $@
	echo 'bridge=br0' >> $@
	echo 'ssid=$(strip ${LAN_SSID})' >> $@
	echo 'hw_mode=g' >> $@
	echo 'channel=$(strip ${LAN_CHANNEL})' >> $@
	echo 'wmm_enabled=0' >> $@
	echo 'macaddr_acl=0' >> $@
	echo 'auth_algs=1' >> $@
	echo 'ignore_broadcast_ssid=0' >> $@
	echo 'wpa=2' >> $@
	echo 'wpa_passphrase=$(strip ${LAN_PASSPHRASE})' >> $@
	echo 'wpa_key_mgmt=WPA-PSK' >> $@
	echo 'wpa_pairwise=TKIP' >> $@
	echo 'rsn_pairwise=CCMP' >> $@
endif
endif

# show IPs etc on login screen
/etc/issue.d/rasping.issue:
	rm -f $@
ifndef CLEAN
	mkdir -p $(dir $@)
	echo '\e{bold}Raspberry Pi NAT Gateway' >> $@
	echo 'WAN MAC : '$$(cat /sys/class/net/eth0/address) >> $@
	echo 'WAN IP  : \4{eth0}' >> $@
	echo 'LAN IP  : \4{br0}' >> $@
	echo '\e{reset}' >> $@
endif

# kernel configuration
/etc/sysctl.d/rasping.conf:
	rm -f $@
ifndef CLEAN
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'net.ipv6.conf.all.disable_ipv6=1' >> $@
	echo 'net.ipv4.ip_forward=1' >> $@
	echo 'net.ipv4.conf.all.route_localnet=1' >> $@
	echo 'nes.ipv4.conf.all.rp_filter=1' >> $@
	echo 'net.ipv4.conf.all.accept_redirects=0' >> $@
	echo 'net.ipv4.tcp_syncookies=1' >> $@
endif

# tell networkd to createa a bridge device
/etc/systemd/network/rasping-br0.netdev:
	rm -f $@
ifndef CLEAN
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo '[NetDev]' >> $@
	echo 'Name=br0' >> $@
	echo 'Kind=bridge' >> $@
endif

# tell networkd about bridge LAN_IP address
/etc/systemd/network/rasping-br0.network:
	rm -f $@
ifndef CLEAN
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo '[Match]' >> $@
	echo 'Name=br0' >> $@
	echo >> $@
	echo '[Network]' >> $@
	echo 'Address=${LAN_IP}/24' >> $@
	echo 'ConfigureWithoutCarrier=true' >> $@
endif

# tell networkd to attach everything except eth0 and br0 to the bridge
/etc/systemd/network/rasping-bridged.network:
	rm -f $@
ifndef CLEAN
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo '[Match]' >> $@
	echo 'Name=!eth0 !br0' >> $@
	echo >> $@
	echo '[Network]' >> $@
	echo 'Bridge=br0' >> $@
endif

.PHONY: clean uninstall
clean:
	${MAKE} CLEAN=1
	@echo "CLEAN COMPLETE"

uninstall:
	${MAKE} CLEAN=2
	@echo "UNINSTALL COMPLETE"

endif
