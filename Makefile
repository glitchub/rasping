# Raspberry PI NAT Gateway

# Make sure we're running the right code
#feq ($(shell grep "Raspberry Pi reference 2019-06-20" /etc/rpi-issue),)
#(error "Requires Raspberry Pi running 2019-06-20-raspbin-buster-lite.img")
#ndif

# package to install
PACKAGES=iptables-persistent $(if $(strip ${LAN_SSID}),hostapd)

# packages to unconditionally remove
PURGEPACKAGES=dnsmasq avahi-daemon

# files to copy from overlay to the root
OVERLAY=$(shell find overlay -type f,l -printf "%P ")

# files to generate or alter
FILES=/etc/iptables/rules.v4 /etc/iptables/rules.v6
FILES+=/etc/systemd/network/rasping-wan.network /etc/systemd/network/rasping-lan.network /etc/systemd/network/rasping-br0.network
FILES+=/etc/default/hostapd /etc/hostapd/rasping.conf
FILES+=/etc/wpa_supplicant-wlan0.conf

# legacy, files to cleanse but do not delete
FILES+=/etc/dhcpcd.conf

# legacy, files to delete
PURGEFILES=/etc/dnsmasq.d/rasping.conf /etc/systemd/network/rasping-eth1.network /etc/systemd/network/rasping/eth2.network

# apt install and remove functions (must be 'call'ed)
INSTALL=DEBIAN_FRONTEND=noninteractive apt install -y $1
REMOVE=DEBIAN_FRONTEND=noninteractive apt remove --autoremove --purge -y $1

# systemctl enable and disable functions (must be 'call'ed)
ENABLE=systemctl unmask $1 && systemctl enable $1 && systemctl restart $1
DISABLE=systemctl --quiet is-enabled $1 && systemctl disable --now $1 || true

ifneq (${USER},root)
# become root if not already
default ${MAKECMDGOALS}:; sudo -E ${MAKE} ${MAKECMDGOALS}
else

include rasping.cfg
ifeq ($(strip ${LAN_IP}),)
$(error Must specify LAN_IP)
endif

ifneq ($(strip ${LAN_SSID}),)
ifneq ($(strip ${WAN_SSID}),)
$(error Must not enable LAN_SSID and WAN_SSID at the same time)
endif
endif

ifneq ($(strip ${SSH_CLIENT}),)
UNBLOCK += ${UNBLOCK_IF_SSH}
endif

# recreate everything
.PHONY: install PACKAGES ${OVERLAY} ${FILES}

install: PACKAGES ${OVERLAY} ${FILES}
	# delete legacy packages
	$(call REMOVE,${PURGEPACKAGES})
	rm -rf ${PURGEFILES}
ifndef CLEAN
	$(call DISABLE,dhcpcd)
	$(call DISABLE,wpa-supplicant)
ifneq ($(strip ${WAN_SSID}),)
	$(call ENABLE,wpa_supplicant@wlan0)
endif
	$(call ENABLE,systemd-networkd)
ifneq ($(strip ${LAN_SSID}),)
	$(call ENABLE,hostapd)
endif
	@echo "INSTALL COMPLETE!"
else
	$(call DISABLE,wpa_supplicant@wlan0)
	$(call DISABLE,hostapd)
	$(call DISABLE,systemd-networkd)
	$(call ENABLE,dhcpcd)
endif

ifndef CLEAN
# Install packages first
PACKAGES:
	$(call INSTALL,${PACKAGES})

# Install overlay after packages
${OVERLAY}: PACKAGES
	mkdir -p /$(dir $@)
	cp -vP overlay/$@ /$@

# Update files after overlay
${FILES}: ${OVERLAY}
else
# Delete files before overlay
${OVERLAY}: ${FILES}
	rm -f /$@

# Delete overlay before packages
PACKAGES: ${OVERLAY}
ifeq (${CLEAN},2)
	$(call REMOVE,${PACKAGES})
endif
endif

# configure NAT, block everything on the WAN except as defined by UNBLOCK or FORWARD
/etc/iptables/rules.v4:
	iptables -F
	iptables -P INPUT ACCEPT
	iptables -F -tnat
ifndef CLEAN
	iptables -P INPUT DROP
ifeq ($(strip $(WAN_SSID)),)	
	iptables -A INPUT ! -i eth0 -j ACCEPT
else	
	iptables -A INPUT ! -i wlan0 -j ACCEPT
endif	
	iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
ifeq ($(strip $(WAN_SSID)),)
	iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
else	
	iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
endif	
	
ifneq ($(strip ${UNBLOCK}),)
	for p in ${UNBLOCK}; do iptables -A INPUT -p tcp --dport $$p -j ACCEPT; done
endif
ifneq ($(strip ${FORWARD}),)
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

# cleanse legacy dhcpcd config
/etc/dhcpcd.conf:
	sed -i '/rasping start/,/rasping end/d' $@ || true

# tell networkd about wan device
/etc/systemd/network/rasping-wan.network:
	rm -f $@
ifndef CLEAN
	mkdir -p $(dir $@)
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo '[Match]' >> $@
ifneq ($(strip ${WAN_SSID}),)
	echo 'Name=wlan0' >> $@
else
	echo 'Name=eth0' >> $@
endif
	echo 'ConfigureWithoutCarrier=true' >> $@
	echo >> $@
	echo '[Network]' >> $@
ifneq ($(strip ${WAN_IP}),)
	echo 'Address=${WAN_IP}' >> $@
	echo 'Gateway=${WAN_GW}' >> $@
	echo 'DNS=${WAN_DNS}' >> $@
else
	echo 'DHCP=ipv4' >> $@
endif
endif

# tell networkd about lan devices
/etc/systemd/network/rasping-lan.network:
	rm -f $@
ifndef CLEAN
	mkdir -p $(dir $@)
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo '[Match]' >> $@
ifeq ($(strip ${WAN_SSID}),)
	echo 'Name=eth[1-9]' >> $@
else
	echo 'Name=eth*' >> $@
endif
	echo >> $@
	echo '[Network]' >> $@
	echo 'Bridge=br0' >> $@
endif

ifneq ($(strip ${DHCP_RANGE}),)
# convert DHCP_RANGE=firstIP,lastIP to pool offset and size
COMMA=,
r=$(subst $(COMMA), ,${DHCP_RANGE})
offset=$(lastword $(subst ., ,$(firstword $r)))
size=$(shell echo $$(($(lastword $(subst ., ,$(lastword $r)))-${offset}+1)))
endif

# tell networkd about the lan bridge
/etc/systemd/network/rasping-br0.network:
	rm -f $@
ifndef CLEAN
	mkdir -p $(dir $@)
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo '[Match]' >> $@
	echo 'Name=br0' >> $@
	echo >> $@
	echo '[Network]' >> $@
	echo 'Address=${LAN_IP}/24' >> $@
	echo 'ConfigureWithoutCarrier=true' >> $@
ifneq ($(strip ${DHCP_RANGE}),)
	echo 'DHCPServer=yes' >> $@
	echo >> $@
	echo '[DHCPServer]' >> $@
	echo 'PoolOffset=${offset}' >> $@
	echo 'PoolSize=${size}' >> $@
endif
endif

# enable hostapd if LAN_SSID defined
/etc/default/hostapd:
	sed -i '/rasping start/,/rasping end/d' $@ || true # first delete the old
ifndef CLEAN
ifeq ($(strip ${LAN_SSID}),)
	mkdir -p $(dir $@)
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
ifneq ($(strip ${LAN_SSID}),)
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

/etc/wpa_supplicant/wpa_supplicant-wlan0.conf:
	rm -f $@
ifndef CLEAN
ifneq ($(strip ${WAN_SSID}),)
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev' >> $@
	echo 'update_config=1' >>> $@
	echo 'country=US' >> $@
	echo 'network={' >> $@
	echo '   ssid="$(strip ${WAN_SSID})' >> $@
	echo '   psk=$(strip ${WAN_PASSPHRASE})' >> $@
	echo '   key_mgmt=WPA-PSK' >> $@
	echo '}' >> $@
endif
endif

.PHONY: clean uninstall
clean:
	${MAKE} CLEAN=1
	@echo "CLEAN COMPLETE"

uninstall:
	${MAKE} CLEAN=2
	@echo "UNINSTALL COMPLETE"
endif
