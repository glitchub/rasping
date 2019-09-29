# Raspberry PI NAT Gateway
ifeq ($(shell [ -f /etc/rpi-issue ] && [ $$(systemd --version | awk '{print $$2;exit}') -ge 241 ] && echo yes),)
$(error Requires Raspberry Pi with systemd version 241 or later)
endif

ifneq (${USER},root)
# become root if not already
default ${MAKECMDGOALS}:; sudo -E ${MAKE} ${MAKECMDGOALS}
else

# package to install
PACKAGES=iptables-persistent $(if $(strip ${LAN_SSID}),hostapd)

# files to generate or alter
FILES =  /etc/default/hostapd
FILES += /etc/hostapd/rasping.conf
FILES += /etc/iptables/rules.v4
FILES += /etc/iptables/rules.v6
FILES += /etc/issue.d/rasping.issue
FILES += /etc/resolvconf.conf
FILES += /etc/sysctl.d/rasping.conf
FILES += /etc/systemd/network/rasping-br0.network
FILES += /etc/systemd/network/rasping-lan.network
FILES += /etc/systemd/network/rasping.netdev
FILES += /etc/systemd/network/rasping-wan.network
FILES += /etc/systemd/resolved.conf
FILES += /etc/wpa_supplicant/wpa_supplicant-wlan0.conf

# legacy, cleanse but do not create
FILES+=/etc/dhcpcd.conf

# apt install and remove functions (must be 'call'ed)
INSTALL=DEBIAN_FRONTEND=noninteractive apt install -y $1
REMOVE=DEBIAN_FRONTEND=noninteractive apt remove --autoremove --purge -y $1

# systemctl enable and disable functions (must be 'call'ed)
ENABLE=systemctl unmask $1 && systemctl enable $1
DISABLE=systemctl --quiet is-enabled $1 && systemctl disable --now $1 && systemctl mask $1 || true

# escape string for use in shell single quotes
quote=$(subst ','\'',$1)

include rasping.cfg

# sanitize and sanity check
LAN_IP:=$(strip ${LAN_IP})
DHCP_RANGE:=$(strip ${DHCP_RANGE})
UNBLOCK:=$(strip ${UNBLOCK})
FORWARD:=$(strip ${FORWARD})
LAN_SSID:=$(strip ${LAN_SSID})
LAN_PASSPHRASE:=$(strip ${LAN_PASSPHRASE})
WAN_SSID:=$(strip ${WAN_SSID})
WAN_PASSPHRASE:=$(strip ${WAN_PASSPHRASE})
LAN_CHANNEL:=$(strip ${LAN_CHANNEL})
WAN_IP:=$(strip ${WAN_IP})
WAN_GW:=$(strip ${WAN_GW})
WAN_DNS:=$(strip ${WAN_DNS})
COUNTRY:=$(strip ${COUNTRY})

ifndef LAN_IP
$(error Must define LAN_IP)
endif
$(info Using LAN_IP = "${LAN_IP}")

ifdef DHCP_RANGE
# convert first,last to dhcp pool offset and size
# Handleslegacy IP,IP or octet,octet
COMMA=,
r=$(subst $(COMMA), ,${DHCP_RANGE})
dhcpoffset=$(lastword $(subst ., ,$(firstword $r)))
dhcpsize=$(shell echo $$(($(lastword $(subst ., ,$(lastword $r)))-${dhcpoffset}+1)))
$(info Using DHCP_RANGE = "${DHCP_RANGE}" (offset=${dhcpoffset}, size=${dhcpsize}))
endif

ifdef UNBLOCK
$(info Using UNBLOCK = "${UNBLOCK}")
endif

ifdef LAN_SSID
ifndef LAN_PASSPHRASE
$(error Must define LAN_PASSPHRASE with LAN_SSID)
endif
ifndef LAN_CHANNEL
$(error Must define LAN_CHANNEL with LAN_SSID)
endif
ifndef COUNTRY
$(error Must define COUNTRY with LAN_SSID)
endif
$(info Using LAN_SSID="${LAN_SSID}", LAN_PASSPHRASE="${LAN_PASSPHRASE}", LAN_CHANNEL="${LAN_CHANNEL}", COUNTRY="${COUNTRY}")
endif

ifdef WAN_SSID
ifndef WAN_PASSPHRASE
$(error Must define WAN_PASSHRASE with WAN_SSID)
endif
ifndef COUNTRY
$(error Must define COUNTRY with WAN_SSID)
endif
$(info Using WAN_SSID="${WAN_SSID}", WAN_PASSPHRASE="${WAN_PASSPHRASE}", COUNTRY="${COUNTRY}")
endif

ifdef WAN_IP
ifndef WAN_GW
$(error Must define WAN_GW with WAN_IP)
endif
ifndef WAN_DNS
$(error Must define WAN_DNS with WAN_IP)
endif
$(info Using WAN_IP="${WAN_IP}", WAN_GW="${WAN_GW}", WAN_DNS="${WAN_DNS}")
endif

# recreate everything
.PHONY: install PACKAGES ${FILES}

install: PACKAGES ${FILES}
ifndef CLEAN
	$(call DISABLE,dhcpcd)
	$(call DISABLE,avahi-daemon)
	$(call DISABLE,avahi-daemon.socket)
	$(call DISABLE,networking)
	$(call DISABLE,wpa-supplicant)
	$(call DISABLE,dnsmasq)
	$(call ENABLE,systemd-networkd)
	$(call ENABLE,systemd-resolved)
	ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
ifdef WAN_SSID
	$(call ENABLE,wpa_supplicant@wlan0)
endif
ifdef LAN_SSID
	$(call ENABLE,hostapd)
endif
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
ifeq (${CLEAN},)
	@echo "INSTALL COMPLETE!"
else ifeq (${CLEAN},1)
	@echo "CLEAN COMPLETE!"
else ifeq (${CLEAN},2)
	@echo "UNINSTALL COMPLETE!"
endif
	@echo "Please reboot now."

ifndef CLEAN
# Install packages first
PACKAGES:
	$(call INSTALL,${PACKAGES})

# Update files after packages
${FILES}: ${PACKAGES}
else
# Delete files before packages
PACKAGES: ${FILES}
ifeq (${CLEAN},2)
	$(call REMOVE,${PACKAGES})
endif
endif

# add rasping to hostapd if LAN_SSID defined
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

# create hostapd config if LAN_SSID is defined
/etc/hostapd/rasping.conf:
	rm -f $@
ifndef CLEAN
	mkdir -p $(dir $@)
ifdef LAN_SSID
	echo '# Raspberry Pi NAT Gateway' >> $@
ifdef WAN_SSID
	echo 'interface=wlan1' >> $@
else
	echo 'interface=wlan0' >> $@
endif
	echo 'bridge=br0' >> $@
	echo 'ssid=$(call quote,${LAN_SSID})' >> $@
	echo 'ieee80211d=1' >> $@
	echo 'country_code=${COUNTRY}' >> $@
	echo 'channel=${LAN_CHANNEL}' >> $@
ifneq ($(shell test ${LAN_CHANNEL} -gt 14 && echo yes),)
	echo 'hw_mode=a' >> $@
	echo 'ieee80211n=1' >> $@
	echo 'ieee80211ac=1' >> $@
else
	echo 'hw_mode=g' >> $@
	echo 'ieee80211n=1' >> $@
endif
	echo 'wmm_enabled=0' >> $@
	echo 'macaddr_acl=0' >> $@
	echo 'ignore_broadcast_ssid=0' >> $@
	echo 'auth_algs=1' >> $@
	echo 'wpa=2' >> $@
	echo 'wpa_passphrase=$(call quote,${LAN_PASSPHRASE})' >> $@
	echo 'wpa_key_mgmt=WPA-PSK' >> $@
	echo 'wpa_pairwise=TKIP' >> $@
	echo 'rsn_pairwise=CCMP' >> $@
endif
endif

# configure NAT, block everything on the WAN except as defined by UNBLOCK or FORWARD
/etc/iptables/rules.v4:
	iptables -P INPUT ACCEPT
	iptables -F
	iptables -F -tnat
ifndef CLEAN
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
	iptables -P INPUT DROP
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

# show status on login screen
/etc/issue.d/rasping.issue:
	rm -f $(dir $@)/rasping* # this also deletes legacy rasping.X.issue
ifndef CLEAN
	mkdir -p $(dir $@)
	echo '\e{bold}Raspberry Pi NAT gateway' >> $@
ifdef WAN_SSID
	echo 'WAN MAC: '$(cat /sys/class/net/wlan0/address) >> $@
	echo 'WAN IP : \4{wlan0}' >> $@
else
	echo 'WAN MAC: '$(cat /sys/class/net/eth1/address) >> $@
	echo 'WAN IP : \4{eth0}' >> $@
endif
	echo 'LAN IP : \4{br0}' >> $@
	echo '\e{reset}' >> $@
endif

# disable resolvconf.conf, if it's installed
/etc/resolvconf.conf:
	sed -i '/rasping start/,/rasping end/d' $@ || true # first delete the old
ifndef CLEAN
	if [ -f $@ ]; then \
	  echo '# rasping start' >> $@; \
	  echo '# Raspberry Pi NAT Gateway' >> $@; \
	  echo 'resolvconf=NO' >> $@; \
	  echo '# rasping end' >> $@; \
	fi
endif

# kernel configuration
/etc/sysctl.d/rasping.conf:
	rm -f $@
ifndef CLEAN
	mkdir -p $(dir $@)
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'net.ipv6.conf.all.disable_ipv6=1' >> $@
	echo 'net.ipv4.ip_forward=1' >> $@
	echo 'net.ipv4.conf.all.route_localnet=1' >> $@
	echo 'nes.ipv4.conf.all.rp_filter=1' >> $@
	echo 'net.ipv4.conf.all.accept_redirects=0' >> $@
	echo 'net.ipv4.tcp_syncookies=1' >> $@
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
	echo 'PoolOffset=${dhcpoffset}' >> $@
	echo 'PoolSize=${dhcpsize}' >> $@
	echo 'MaxLeaseTimeSec=3600' >> $@
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
	echo 'Name=eth* usb*' >> $@
else
	echo 'Name=eth[1-9] usb*' >> $@
endif
	echo '[Network]' >> $@
	echo 'LinkLocalAddressing=no' >> $@
	echo 'Bridge=br0' >> $@
endif

# tell networkd about the bridge
/etc/systemd/network/rasping.netdev:
	rf -f $@
ifndef CLEAN
	mkdir -p $(dir $@)
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo '[netdev]' >> $@
	echo 'Name=br0' >> $@
	echo 'kind=bridge' >> $@
endif

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
endif
endif

# configure system resolved
/etc/systemd/resolved.conf:
	sed -i '/rasping start/,/rasping end/d' $@ || true # first delete the old
ifndef CLEAN
	echo '# rasping start' >> $@
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'FallbackDNS=1.1.1.1 8.8.8.8' >> $@
	echo 'DNSSEC=no' >> $@
	echo '# rasping end' >> $@
endif

# attach wlan0 to router if WAN_SSID
/etc/wpa_supplicant/wpa_supplicant-wlan0.conf:
	rm -f $@
ifndef CLEAN
ifdef WAN_SSID
	mkdir -p $(dir $@)
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev' >> $@
	echo 'update_config=1' >> $@
	echo 'country=${COUNTRY}' >> $@
	echo 'network={' >> $@
	echo '	scan_ssid=1' >> $@
	echo '	key_mgmt=WPA-PSK' >> $@
	echo '	ssid="$(call quote,${WAN_SSID})"' >> $@
	echo '	psk="$(call quote,${WAN_PASSPHRASE})"' >> $@
	echo '}' >> $@
endif
endif

# always delete legacy config from dhcpcd.conf
/etc/dhcpcd.conf:
	sed -i '/rasping start/,/rasping end/d' $@ || true

.PHONY: clean uninstall

clean:; ${MAKE} CLEAN=1

uninstall:; ${MAKE} CLEAN=2
endif
