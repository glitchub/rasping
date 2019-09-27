# Raspberry PI NAT Gateway

# Make sure we're running the right code
#feq ($(shell grep "Raspberry Pi reference 2019-06-20" /etc/rpi-issue),)
#(error "Requires Raspberry Pi running 2019-06-20-raspbin-buster-lite.img")
#ndif

# package to install
PACKAGES=iptables-persistent $(if $(strip ${LAN_SSID}),hostapd)

# files to copy from overlay to the root
OVERLAY=$(shell find overlay -type f,l -printf "%P ")

# files to generate or alter
FILES=/etc/iptables/rules.v4 /etc/iptables/rules.v6
FILES+=/etc/systemd/network/rasping-wan.network /etc/systemd/network/rasping-lan.network /etc/systemd/network/rasping-br0.network
FILES+=/etc/default/hostapd /etc/hostapd/rasping.conf
FILES+=/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
FILES+=/etc/resolvconf.conf /etc/systemd/resolved.conf

# legacy, files to cleanse but do not delete
FILES+=/etc/dhcpcd.conf

# apt install and remove functions (must be 'call'ed)
INSTALL=DEBIAN_FRONTEND=noninteractive apt install -y $1
REMOVE=DEBIAN_FRONTEND=noninteractive apt remove --autoremove --purge -y $1

# systemctl enable and disable functions (must be 'call'ed)
ENABLE=systemctl unmask $1 && systemctl enable $1 && systemctl restart $1
DISABLE=systemctl --quiet is-enabled $1 && systemctl disable --now $1 && systemctl mask $1 || true

ifneq (${USER},root)
# become root if not already
default ${MAKECMDGOALS}:; sudo -E ${MAKE} ${MAKECMDGOALS}
else

include rasping.cfg

# sanitize and sanity check
LAN_IP:=$(strip ${LAN_IP})
DHCP_RANGE:=$(strip ${DHCP_RANGE})
UNBLOCK:=$(strip ${UNBLOCK})
FORWARD:=$(strip ${FORWARD})
LAN_SSID:=$(strip ${LAN_SSID})
LAN_PASSPHRASE:=$(strip ${LAN_PASSPHRASE})
LAN_CHANNEL:=$(strip ${LAN_CHANNEL})
WAN_SSID:=$(strip ${WAN_SSID})
WAN_PASSPHRASE:=$(strip ${WAN_PASSPHRASE})
WAN_IP:=$(strip ${WAN_IP})
WAN_GW:=$(strip ${WAN_GW})
WAN_DNS:=$(strip ${WAN_DNS})
COUNTRY:=$(strip ${COUNTRY})

ifdef SSH_CLIENT
UNBLOCK:=$(strip ${UNBLOCK} ${UNBLOCK_IF_SSH})
endif

ifndef LAN_IP
$(error Must define LAN_IP)
endif
$(warning Using LAN_IP = ${LAN_IP})

ifdef DHCP_RANGE
$(warning Using DHCP_RANGE = "${DHCP_RANGE}")	
endif

ifdef LAN_SSID
ifdef WAN_SSID
$(error Must not define LAN_SSID and WAN_SSID at the same time)
endif
ifndef LAN_PASSPHRASE
$(error Must define LAN_PASSPHRASE with LAN_SSID)	
endif
ifndef LAN_CHANNEL
$(error Must define LAN_CHANNEL with LAN_SSID)
endif
ifndef COUNTRY
$(error Must define COUNTRY with LAN_SSID)
endif
$(warning Using LAN_SSID="${LAN_SSID}", LAN_PASSPHRASE="${LAN_PASSPHRASE}", LAN_CHANNEL="${LAN_CHANNEL}", COUNTRY="${COUNTRY}")
endif

ifdef WAN_SSID
ifndef WAN_PASSPHRASE
$(error Must define WAN_PASSHRASE with WAN_SSID)
endif
ifndef COUNTRY
$(error Must define COUNTRY with WAN_SSID)
endif
$(warning Using WAN_SSID="${WAN_SSID}", WAN_PASSPHRASE="${WAN_PASSPHRASE}", COUNTRY="${COUNTRY}")
endif

ifdef WAN_IP
ifndef WAN_GW
$(error Must define WAN_GW with WAN_IP)
endif  
ifndef WAN_DNS
$(error Must define WAN_DNS with WAN_IP)
endif
$(warning Using WAN_IP="${WAN_IP}", WAN_GW="${WAN_GW}", WAN_DNS="${WAN_DNS}")
endif

# recreate everything
.PHONY: install PACKAGES ${OVERLAY} ${FILES}

install: PACKAGES ${OVERLAY} ${FILES}
ifndef CLEAN
	$(call DISABLE,avahi-daemon)
	$(call DISABLE,avahi-daemon.socket)
        $(call DISABLE,dnsmasq)
	$(call DISABLE,networking)
	$(call DISABLE,dhcpcd)
	$(call DISABLE,wpa-supplicant)
	$(call ENABLE,systemd-networkd)
	$(call ENABLE,systemd-resolved)
	ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
ifdef WAN_SSID
	$(call ENABLE,wpa_supplicant@wlan0)
endif
ifdef LAN_SSID
	$(call ENABLE,hostapd)
endif
	@echo "INSTALL COMPLETE!"
else
	$(call DISABLE,wpa_supplicant@wlan0)
	$(call DISABLE,hostapd)
	$(call DISABLE,systemd-networkd)
	$(call DISABLE,systemd-networkd.socket)
	$(call DISABLE,systemd-resolved)
	rm /etc/resolv.conf
	$(call ENABLE,dhcpcd)
	$(call ENABLE,networking)
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
ifdef WAN_SSID	
	iptables -A INPUT ! -i wlan0 -j ACCEPT
else	
	iptables -A INPUT ! -i eth0 -j ACCEPT
endif	
	iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
ifdef WAN_SSID
	iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
else	
	iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
endif	
	
ifdef UNBLOCK
	for p in ${UNBLOCK}; do iptables -A INPUT -p tcp --dport $$p -j ACCEPT; done
endif
ifdef FORWARD
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
ifdef WAN_SSID
	echo 'Name=wlan0' >> $@
else
	echo 'Name=eth0' >> $@
endif
	echo '[Network]' >> $@
	echo 'LinkLocalAddressing=no' >> $@
ifdef WAN_IP
	echo 'Address=${WAN_IP}' >> $@
	echo 'Gateway=${WAN_GW}' >> $@
	echo 'DNS=${WAN_DNS}' >> $@
else
	echo 'DHCP=ipv4' >> $@
	# echo '[DHCPv4]' >> $@
	# echo 'ClientIdentifier=mac' >> $@
	# echo 'UseTimezone=yes' >> $@
endif
endif

# tell networkd about lan devices
/etc/systemd/network/rasping-lan.network:
	rm -f $@
ifndef CLEAN
	mkdir -p $(dir $@)
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo '[Match]' >> $@
ifdef WAN_SSID
	echo 'Name=eth*' >> $@
else
	echo 'Name=eth[1-9]' >> $@
endif
	echo '[Network]' >> $@
	echo 'LinkLocalAddressing=no' >> $@
	echo 'Bridge=br0' >> $@
endif

ifneq (${DHCP_RANGE},)
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
	echo '[Network]' >> $@
	echo 'Address=${LAN_IP}/24' >> $@
	echo 'ConfigureWithoutCarrier=true' >> $@
	echo 'LinkLocalAddressing=no' >> $@
ifdef DHCP_RANGE
	echo 'DHCPServer=yes' >> $@
	echo '[DHCPServer]' >> $@
	echo 'PoolOffset=${offset}' >> $@
	echo 'PoolSize=${size}' >> $@
	echo 'MaxLeaseTimeSec=3600' >> $@
endif
endif

# enable hostapd if LAN_SSID defined
/etc/default/hostapd:
	sed -i '/rasping start/,/rasping end/d' $@ || true # first delete the old
ifndef CLEAN
ifdef LAN_SSID
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
ifdef LAN_SSID
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'interface=wlan0' >> $@
	echo 'bridge=br0' >> $@
	echo 'ssid=${LAN_SSID}' >> $@
	echo 'hw_mode=g' >> $@
	echo 'ieee80211d=1' >> $@
	echo 'country_code=${COUNTRY}' >> $@
	echo 'channel=${LAN_CHANNEL}' >> $@
	echo 'wmm_enabled=0' >> $@
	echo 'macaddr_acl=0' >> $@
	echo 'auth_algs=1' >> $@
	echo 'ignore_broadcast_ssid=0' >> $@
        echo 'auth_algs=1' >> $@
	echo 'wpa=2' >> $@
	echo 'wpa_passphrase=${LAN_PASSPHRASE}' >> $@
	echo 'wpa_key_mgmt=WPA-PSK' >> $@
	echo 'wpa_pairwise=TKIP' >> $@
	echo 'rsn_pairwise=CCMP' >> $@
endif
endif

/etc/wpa_supplicant/wpa_supplicant-wlan0.conf:
	rm -f $@
ifndef CLEAN
ifdef WAN_SSID
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev' >> $@
	echo 'update_config=1' >> $@
	echo 'country=${COUNTRY}' >> $@
	echo 'network={' >> $@
	echo '   scan_ssid=1' >> $@
	echo '   key_mgmt=WPA-PSK' >> $@
	echo '   ssid="${WAN_SSID}"' >> $@
	echo '   psk="${WAN_PASSPHRASE}"' >> $@
	echo '}' >> $@
endif
endif

/etc/resolvconf.conf:
	sed -i '/rasping start/,/rasping end/d' $@ || true # first delete the old
ifndef CLEAN
	echo '# rasping start' >> $@
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'resolvconf=NO' >> $@
	echo '# rasping end' >> $@
endif

/etc/systemd/resolved.conf:
	sed -i '/rasping start/,/rasping end/d' $@ || true # first delete the old
ifndef CLEAN
	echo '# rasping start' >> $@
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'DNSSEC=no' >> $@
	echo '# rasping end' >> $@
endif

.PHONY: clean uninstall
clean:
	${MAKE} CLEAN=1
	@echo "CLEAN COMPLETE"

uninstall:
	${MAKE} CLEAN=2
	@echo "UNINSTALL COMPLETE"
endif
