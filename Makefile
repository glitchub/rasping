# Raspberry PI NAT Gateway

# Make sure we're running the right code
ifeq ($(shell grep "Raspberry Pi reference 2019-06-20" /etc/rpi-issue),)
$(error "Requires Raspberry Pi running 2019-06-20-raspbin-buster-lite.img")
endif

ifneq (${USER},root)
# become root if not already
default ${MAKECMDGOALS}:; sudo -E ${MAKE} ${MAKECMDGOALS}
else

include rasping.cfg
ifeq ($(strip ${LAN_IP}),)
$(error Must specify LAN_IP)
endif

# package to install
PACKAGES=iptables-persistent dnsmasq $(if $(strip ${LAN_SSID}),hostapd)

# files to copy from overlay to the root
OVERLAY=$(shell find overlay -type f,l -printf "%P ")

# files to generate or alter
FILES=/etc/iptables/rules.v4 /etc/iptables/rules.v6 /etc/dhcpcd.conf /etc/dnsmasq.d/rasping.conf /etc/systemd/network/rasping-br0.network $(if $(strip ${LAN_SSID}),/etc/default/hostapd /etc/hostapd/rasping.conf)

# recreate everything
.PHONY: install PACKAGES ${OVERLAY} ${FILES}

install: PACKAGES ${OVERLAY} ${FILES}
ifndef CLEAN
	systemctl enable systemd-networkd
	systemctl disable wpa_supplicant
ifneq ($(strip ${LAN_SSID}),)
	systemctl unmask hostapd
	systemctl enable hostapd
endif
	@echo "INSTALL COMPLETE!"
endif

ifndef CLEAN
# Install packages first
PACKAGES:
	DEBIAN_FRONTEND=noninteractive apt install -y ${PACKAGES}

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

# append dhcpcd.conf to set eth0 address, static if WAN_IP is defined
/etc/dhcpcd.conf:
	sed -i '/rasping start/,/rasping end/d' $@ # first delete the old
ifndef CLEAN
	{\
	    echo '# rasping start';\
	    echo '# Raspberry Pi NAT Gateway';\
	    echo 'allowinterfaces eth0';\
	    echo 'ipv4only';\
	    echo 'noipv4ll';\
	    echo 'noalias';\
	} >> $@
ifneq ($(strip ${WAN_IP}),)
	{\
	    echo 'interface eth0';\
	    echo 'static ip_address=${WAN_IP}';\
	    echo 'static routers=${WAN_GW}';\
	    echo 'static domain_name_server=${WAN_DNS}';\
	    echo 'nolink';\
	} >> $@
endif
	echo '# rasping end' >> $@
endif

# configure dnsmasq to serve on br0
/etc/dnsmasq.d/rasping.conf:
	rm -f $@
ifndef CLEAN
	{\
	    echo '# Raspberry Pi NAT Gateway';\
	    echo 'interface=br0';\
	    $(if $(strip ${DHCP_RANGE}),echo 'dhcp-range=${DHCP_RANGE}';)\
            } > $@
endif

# tell networkd about br0 LAN_IP address
/etc/systemd/network/rasping-br0.network:
	rm -f $@
ifndef CLEAN
	{\
	    echo '# Raspberry Pi NAT Gateway';\
	    echo '[Match]';\
	    echo 'Name=br0';\
	    echo;\
	    echo '[Network]';\
	    echo 'Address=${LAN_IP}/24';\
            echo 'ConfigureWithoutCarrier=true';\
	} > $@
endif

# enable hostapd (if LAN_SSID defined)
/etc/default/hostapd:
	sed -i '/rasping start/,/rasping end/d' $@ # first delete the old
ifndef CLEAN
ifneq ($(strip ${LAN_SSID}),)
	{\
	    echo '# rasping start';\
	    echo '# Raspberry Pi NAT Gateway';\
	    echo 'DAEMON_CONF=/etc/hostapd/rasping.conf';\
	    echo '# rasping end';\
	} >> $@
endif
endif

# create hostapd config (if LAN_SSID is defined)
/etc/hostapd/rasping.conf:
	rm -f $@
ifndef CLEAN
ifneq ($(strip ${LAN_SSID}),)
	{\
	    echo '# Raspberry Pi NAT Gateway';\
	    echo 'interface=wlan0';\
	    echo 'bridge=br0';\
	    echo 'ssid=$(strip ${LAN_SSID})';\
	    echo 'hw_mode=g';\
	    echo 'channel=$(strip ${LAN_CHANNEL})';\
	    echo 'wmm_enabled=0';\
	    echo 'macaddr_acl=0';\
	    echo 'auth_algs=1';\
	    echo 'ignore_broadcast_ssid=0';\
	    echo 'wpa=2';\
	    echo 'wpa_passphrase=$(strip ${LAN_PASSPHRASE})';\
	    echo 'wpa_key_mgmt=WPA-PSK';\
	    echo 'wpa_pairwise=TKIP';\
	    echo 'rsn_pairwise=CCMP';\
	} > $@
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
