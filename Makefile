# Raspberry PI NAT Gateway

ifneq (${USER},root)
# become root if not already
default ${MAKECMDGOALS}:; sudo -E ${MAKE} ${MAKECMDGOALS}
else

# this is undefined by the clean and uninstall targets
INSTALL=1

SHELL=/bin/bash

ifeq ($(shell grep Raspbian.*buster /etc/os-release),)
    $(error Requires raspbian version 10)
endif

include rasping.cfg
override LAN_IP:=$(strip ${LAN_IP})
override LAN_VLAN:=$(strip ${LAN_VLAN})
override DHCP_RANGE:=$(strip ${DHCP_RANGE})
override UNBLOCK:=$(strip ${UNBLOCK})
override FORWARD:=$(strip ${FORWARD})
override PINGABLE:=$(strip ${PINGABLE})
override WAN_IP:=$(strip ${WAN_IP})
override WAN_GW:=$(strip ${WAN_GW})
override WAN_DNS:=$(strip ${WAN_DNS})
override LAN_CHANNEL:=$(strip ${LAN_CHANNEL})
override COUNTRY:=$(strip ${COUNTRY})

# escape ' -> '\'' in ssid's and passphrases
override WAN_SSID:=$(subst ','\'',$(strip ${WAN_SSID}))
override WAN_PASSPHRASE:=$(subst ','\'',$(strip ${WAN_PASSPHRASE}))
override LAN_SSID:=$(subst ','\'',$(strip ${LAN_SSID}))
override LAN_PASSPHRASE:=$(subst ','\'',$(strip ${LAN_PASSPHRASE}))
# ' <- fix vi syntax highlight

ifndef LAN_IP
    $(error Must specify LAN_IP)
endif

ifeq (${LAN_IP},no)
ifdef DHCP_RANGE
    $(error Can't set DHCP_RANGE when LAN_IP=no)
endif
ifdef FORWARD
    $(error Can't set FORWARD when LAN_IP=no)
endif
ifdef WAN_SSID
    $(error Can't set WAN_SSID when LAN_IP=no)
endif
    override LAN_IP:=
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

# packages to install
PACKAGES=iptables-persistent dnsmasq hostapd

# files to generate or alter
FILES = /etc/iptables/rules.v4
FILES += /etc/default/hostapd
FILES += /etc/hostapd/rasping.conf
FILES += /etc/wpa_supplicant/wpa_supplicant.conf
FILES += /etc/dhcpcd.conf
FILES += /etc/dnsmasq.d/rasping.conf
FILES += /etc/issue.d/rasping.issue
FILES += /etc/sysctl.d/rasping.conf
FILES += /lib/systemd/system/autobridge.service
FILES += /lib/systemd/system/autovlan.service
.PHONY: ${FILES}

# NO RULES ABOVE THIS POINT
#
ifndef INSTALL
# cleaning
.PHONY: default down
default: ${FILES}
${FILES}: down              # remove files, but take down the system first
down: legacy
	systemctl disable autobridge || true
	systemctl disable autovlan || true
	systemctl disable wpa_supplicant || true
	systemctl disable hostapd || true
	systemctl mask hostapd || true
	systemctl disable dnsmasq || true
	systemctl mask dnsmasq || true
	raspi-config nonint do_boot_wait 0 # 0==enable

else
# installing
.PHONY: default up packages
default: up
up: ${FILES}                # bring uip the system, but install files first
ifdef WAN_SSID
	rfkill unblock wifi || true
	systemctl enable wpa_supplicant
else
	systemctl disable wpa_supplicant
endif
ifdef LAN_SSID
	rfkill unblock wifi || true
	systemctl unmask hostapd
	systemctl enable hostapd
else
	systemctl disable hostapd || true
	systemctl mask hostapd || true
endif
ifdef LAN_IP
	systemctl unmask dnsmasq
	systemctl enable dnsmasq
else
	systemctl disable dnsmasq || true
	systemctl mask dnsmasq || true
endif
	systemctl enable autobridge
ifdef LAN_VLAN
	systemctl enable autovlan
endif
	raspi-config nonint do_boot_wait 1 # 1 == disable
	@echo 'INSTALL COMPLETE'

${FILES}: packages          # install packages before files

packages: legacy            # purge legacy before packages
	DEBIAN_FRONTEND=noninteractive apt install -y ${PACKAGES}

endif

# expunge legacy stuff
.PHONY: legacy
legacy:
	rm -f /etc/network/interfaces.d/rasping
	rm -f /etc/systemd/network/rasping*
	systemctl disable systemd-networkd || true

# configure NAT, block everything on the WAN except as defined by UNBLOCK or FORWARD
/etc/iptables/rules.v4:
	rm -f /etc/iptables/rules*
	iptables -F
	iptables -P INPUT ACCEPT
	iptables -F -tnat
ifdef INSTALL
	iptables -P INPUT DROP
ifdef LAN_IP
	iptables -A INPUT ! -i ${WANIF} -j ACCEPT
else
	iptables -A INPUT -i lo -j ACCEPT
endif
	iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
ifdef PINGABLE
	iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
endif
ifdef UNBLOCK
	for p in ${UNBLOCK}; do iptables -A INPUT -p tcp --dport $$p -j ACCEPT; done
endif
ifdef LAN_IP
	iptables -t nat -A POSTROUTING -o ${WANIF} -j MASQUERADE
ifdef FORWARD
	# forward incoming and localhost
	for p in ${FORWARD}; do \
		iptables -t nat -A PREROUTING -p tcp --dport $${p%=*} -j DNAT --to $${p#*=}; \
		iptables -t nat -A OUTPUT -o lo -p tcp --dport $${p%=*} -j DNAT --to $${p#*=}; \
	done
endif
endif
	iptables-save -f $@
endif

# Configure WANIF (or br0) via dhcp or static IP
/etc/dhcpcd.conf:
	sed -i '/rasping start/,/rasping end/d' $@
ifdef INSTALL
	echo '# rasping start' >> $@
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'allowinterfaces $(if ${LAN_IP},${WANIF},br0)' >> $@
	echo 'ipv4only' >> $@
	echo 'noipv4ll' >> $@
	echo 'noalias' >> $@
	echo 'timeout 30' >> $@
ifdef WAN_IP
	echo 'interface $(if ${LAN_IP},${WANIF},br0)' >> $@
	echo 'static ip_address=${WAN_IP}' >> $@
	echo 'static routers=${WAN_GW}' >> $@
	echo 'static domain_name_servers=${WAN_DNS}' >> $@
endif
	echo '# rasping end' >> $@
endif

# Configure dnsmasq to serve on br0
/etc/dnsmasq.d/rasping.conf:
	rm -f $@
ifdef INSTALL
ifdef LAN_IP
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'interface=br0' >> $@
ifdef DHCP_RANGE
	echo 'dhcp-range=${DHCP_RANGE}' >> $@
endif
endif
endif

# Enable wpa_supplicant, if WAN_SSID is defined
/etc/wpa_supplicant/wpa_supplicant.conf:
	! [ -e $@ ] || sed -i '/rasping start/,/rasping end/d' $@
ifdef INSTALL
ifdef WAN_SSID
	echo '# rasping start' >> $@
	echo '# Raspberry Pi NAT Gateway' >> $@
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

# Enable hostapd if LAN_SSID defined
/etc/default/hostapd:
	! [ -e $@ ] || sed -i '/rasping start/,/rasping end/d' $@
ifdef INSTALL
ifdef LAN_SSID
	echo '# rasping start' >> $@
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'DAEMON_CONF=/etc/hostapd/rasping.conf' >> $@
	echo 'DAEMON_OPTS="-dd"' >> $@
	echo '# rasping end' >> $@
endif
endif

# Configure hostapd if LAN_SSID defined
/etc/hostapd/rasping.conf:
	rm -f $@
ifdef INSTALL
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
ifdef INSTALL
	mkdir -p $(dir $@)
	echo '\e{bold}Raspberry Pi NAT Gateway' >> $@
ifdef LAN_IP
	echo 'WAN MAC : '$$(cat /sys/class/net/${WANIF}/address) >> $@
	echo 'WAN IP  : \4{${WANIF}}' >> $@
	echo 'LAN IP  : \4{br0}' >> $@
else
	echo 'IP: \4{br0}' >> $@
endif
	echo '\e{reset}' >> $@
endif

# Various kernel config
/etc/sysctl.d/rasping.conf:
	rm -f $@
ifdef INSTALL
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo 'net.ipv6.conf.all.disable_ipv6=1' >> $@
	echo 'net.ipv4.ip_forward=1' >> $@
	echo 'net.ipv4.conf.all.route_localnet=1' >> $@
	echo 'nes.ipv4.conf.all.rp_filter=1' >> $@
	echo 'net.ipv4.conf.all.accept_redirects=0' >> $@
	echo 'net.ipv4.tcp_syncookies=1' >> $@
endif

# Enable autobridge of bridgable interfaces
/lib/systemd/system/autobridge.service:
	rm -f $@
ifdef INSTALL
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo '[Unit]' >> $@
	echo 'Description=Raspberry Pi NAT Gateway autobridge service' >> $@
	echo 'Before=hostapd.service dncpcd.service' >> $@
	echo '[Service]' >> $@
	echo 'ExecStart=${PWD}/autobridge -xwlan* -xbr* $(if ${LAN_IP},-i${LAN_IP}/24 -x${WANIF},-u${WANIF}) $(if ${LAN_VLAN},vlan.*,*) br0' >> $@
	echo '[Install]' >> $@
	echo 'WantedBy=multi-user.target' >> $@
endif

# Enable autovlan
/lib/systemd/system/autovlan.service:
	rm -f $@
ifdef INSTALL
ifdef LAN_VLAN
	echo '# Raspberry Pi NAT Gateway' >> $@
	echo '[Unit]' >> $@
	echo 'Description=Raspberry Pi NAT Gateway autovlan service' >> $@
	echo '[Service]' >> $@
	echo 'ExecStart=${PWD}/autovlan -xvlan* -xwlan* -xbr* -x${WANIF} * ${LAN_VLAN}' >> $@ # never vlan the WAN
	echo '[Install]' >> $@
	echo 'WantedBy=multi-user.target' >> $@
endif
endif

.PHONY: clean uninstall
clean:
	${MAKE} INSTALL=
	@echo 'CLEAN COMPLETE'

uninstall:
	${MAKE} INSTALL=
	DEBIAN_FRONTEND=noninteractive apt remove --autoremove --purge -y ${PACKAGES}
	@echo 'UNINSTALL COMPLETE'

endif
