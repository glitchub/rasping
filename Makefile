# Raspberry PI NAT Gateway

# Make sure we're running the right code
ifeq ($(shell [ -f /etc/rpi-issue ] && [ $$(systemd --version | awk '{print $$2;exit}') -ge 241 ] && echo yes),)
$(error Requires Raspberry Pi with systemd version 241 or later)
endif

ifneq (${USER},root)
# become root if not already
default ${MAKECMDGOALS}:; sudo -E ${MAKE} ${MAKECMDGOALS}
else

SHELL=/bin/bash

include rasping.cfg
override LAN_IP:=$(strip ${LAN_IP})
override DHCP_RANGE:=$(strip ${DHCP_RANGE})
override UNBLOCK:=$(strip ${UNBLOCK})
override FORWARD:=$(strip ${FORWARD})
override WAN_IP:=$(strip ${WAN_IP})
override WAN_GW:=$(strip ${WAN_GW})
override WAN_DNS:=$(strip ${WAN_DNS})
override LAN_CHANNEL:=$(strip ${LAN_CHANNEL})

# escape ' -> '\'' in ssid's and passphrases
override WAN_SSID:=$(subst ','\'',$(strip ${WAN_SSID}))
override WAN_PASSPHRASE:=$(subst ','\'',$(strip ${WAN_PASSPHRASE}))
override LAN_SSID:=$(subst ','\'',$(strip ${LAN_SSID}))
override LAN_PASSPHRASE:=$(subst ','\'',$(strip ${LAN_PASSPHRASE}))
# ' <- fix vi syntax highlight

ifndef LAN_IP
  $(error Must specify LAN_IP)
endif

ifdef WAN_SSID
ifdef LAN_SSID
	$(error Can't set WAN_SSID with LAN_SSID)
endif
ifndef COUNTRY
	$(error Must specifiy COUNTRY with WAN_SSID)
endif
ifndef WAN_PASSPHRASE
	$(error Must set WAN_PASSPHRASE with WAN_SSID)
endif
WANIF=wlan0
else
WANIF=eth0
endif

ifdef LAN_SSID
ifndef COUNTRY
	$(error Must specifiy COUNTRY with LAN_SSID)
endif
ifndef LAN_PASSPHRASE
	$(error Must set LAN_PASSPHRASE with LAN_SSID)
endif
ifndef LAN_CHANNEL
	$(error Must set LAN_CHANNEL with LAN_SSID)
endif
endif

# package to install
PACKAGES=iptables-persistent dnsmasq $(if ${LAN_SSID},hostapd)

# files to generate or alter
FILES = /etc/iptables/rules.v4
FILES += /etc/default/hostapd
FILES += /etc/hostapd/rasping.conf
FILES += /etc/wpa_supplicant/wpa_supplicant.conf
FILES += /etc/dhcpcd.conf
FILES += /etc/dnsmasq.d/rasping.conf
FILES += /etc/issue.d/rasping.issue
FILES += /etc/sysctl.d/rasping.conf
FILES += /etc/systemd/network/rasping-br0.netdev
FILES += /etc/systemd/network/rasping-br0.network
FILES += /etc/systemd/network/rasping-bridged.network

# recreate everything
.PHONY: install PACKAGES ${FILES}

install: PACKAGES ${FILES}
ifndef CLEAN
	systemctl enable systemd-networkd
ifdef WAN_SSID
	systemctl enable wpa_supplicant
else
	systemctl disable wpa_supplicant
endif
ifdef LAN_SSID
	systemctl unmask hostapd
	systemctl enable hostapd
else
	systemctl disable hostapd || true
	systemctl mask hostapd || true
endif
	@echo 'INSTALL COMPLETE'

# Install packages before files
${FILES}: PACKAGES
PACKAGES:
	DEBIAN_FRONTEND=noninteractive apt install -y ${PACKAGES}
else #ifndef CLEAN
# Delete files before packages
PACKAGES: ${FILES}
ifeq (${CLEAN},2)
	DEBIAN_FRONTEND=noninteractive apt remove --autoremove --purge -y ${PACKAGES}
endif
endif

# configure NAT, block everything on the WAN except as defined by UNBLOCK or FORWARD
/etc/iptables/rules.v4:
	rm -f /etc/iptables/rules*
	iptables -F
	iptables -P INPUT ACCEPT
	iptables -F -tnat
ifndef CLEAN
	iptables -P INPUT DROP
	iptables -A INPUT ! -i ${WANIF} -j ACCEPT
	iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
	iptables -t nat -A POSTROUTING -o ${WANIF} -j MASQUERADE
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

# append dhcpcd.conf to set WANIF address, static if WAN_IP is defined
/etc/dhcpcd.conf:
	sed -i '/rasping start/,/rasping end/d' $@
ifndef CLEAN
	echo '# rasping start' >> $@
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'allowinterfaces ${WANIF}' >> $@
	echo 'ipv4only' >> $@
	echo 'noipv4ll' >> $@
	echo 'noalias' >> $@
	echo 'timeout=300' >> $@
ifdef WAN_IP
	echo 'interface ${WANIF}' >> $@
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
ifdef DHCP_RANGE
	echo 'dhcp-range=${DHCP_RANGE}' >> $@
endif
endif

# enable wpa_supplicant, if WAN_SSID is defined
/etc/wpa_supplicant.wpa_supplicant.conf:
	! [ -e $@ ] || sed -i '/rasping start/,/rasping end/d' $@
ifndef CLEAN
ifdef WAN_SSID
	echo '# rasping start' >> $@
	echo 'ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev' >> $@
	echo 'update_config=1' >> $@
	echo 'country=${COUNTRY}' >> $@
	echo 'network={' >> $@
	echo '  ssid=${WAN_SSID}' >> $@
	echo '  psk=${WAN_PASSPHRASE}' >> $@
	echo '  scan_ssid=1' >> $@
	echo '  key_mgmt=WPA-PSK' >> $@
	echo '}' >> $@
	echo '#rasping end' >> $@
endif
endif

# enable hostapd (if LAN_SSID defined)
/etc/default/hostapd:
	! [ -e $@ ] || sed -i '/rasping start/,/rasping end/d' $@
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
	echo 'ssid=${LAN_SSID}' >> $@
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
	echo 'auth_algs=1' >> $@
	echo 'ignore_broadcast_ssid=0' >> $@
	echo 'wpa=2' >> $@
	echo 'wpa_passphrase=${LAN_PASSPHRASE}' >> $@
	echo 'wpa_key_mgmt=WPA-PSK' >> $@
	echo 'wpa_pairwise=TKIP' >> $@
	echo 'rsn_pairwise=CCMP' >> $@
endif
endif

# show IPs etc on login screen
/etc/issue.d/rasping.issue:
	rm -f /etc/issue.d/rasping* # nuke residuals
ifndef CLEAN
	mkdir -p $(dir $@)
	echo '\e{bold}Raspberry Pi NAT Gateway' >> $@
	echo 'WAN MAC : '$$(cat /sys/class/net/${WANIF}/address) >> $@
	echo 'WAN IP  : \4{${WANIF}}' >> $@
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

# tell networkd to create a bridge device, this goes before the others
/etc/systemd/network/rasping-br0.netdev:
	rm -f /etc/systemd/network/rasping* # nuke residuals
ifndef CLEAN
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo '[NetDev]' >> $@
	echo 'Name=br0' >> $@
	echo 'Kind=bridge' >> $@
endif

# tell networkd about bridge LAN_IP address
/etc/systemd/network/rasping-br0.network: /etc/systemd/network/rasping-br0.netdev
ifndef CLEAN
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo '[Match]' >> $@
	echo 'Name=br0' >> $@
	echo >> $@
	echo '[Network]' >> $@
	echo 'Address=${LAN_IP}/24' >> $@
	echo 'ConfigureWithoutCarrier=true' >> $@
endif

# tell networkd to attach everything except WANIF and br0 to the bridge
/etc/systemd/network/rasping-bridged.network: /etc/systemd/network/rasping-br0.netdev
ifndef CLEAN
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo '[Match]' >> $@
	echo 'Name=!${WANIF} !br0' >> $@
	echo >> $@
	echo '[Network]' >> $@
	echo 'Bridge=br0' >> $@
endif

.PHONY: clean uninstall
clean:
	${MAKE} CLEAN=1
	@echo 'CLEAN COMPLETE'

uninstall:
	${MAKE} CLEAN=2
	@echo 'UNINSTALL COMPLETE'

endif
