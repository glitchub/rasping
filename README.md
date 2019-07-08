Rasping - Raspberry Pi NAT Gateway

Configure a Raspberry PI 3 or equivalent as a ethernet NAT gateway.

Physical configuration:

    The Pi's ethernet interface connects to the WAN. By default it expects to
    receive an address via DHCP, but can also be configiured to use static IP.

    A USB ethernet dongle attachs to the LAN and gets a static IP address. By
    default, DHCP is served to the upper-half of the LAN IP range, the lower
    half is not assigned and available for arbitrary static IP. The LAN
    interface also provides DNS.

    The Pi acts as a NAT router and a DNS server.
    
To install:

    Download the SDcard image:
        
        wget https://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2019-06-24/2019-06-20-raspbian-buster-lite.zip

    Unzip and extract file 2019-06-20-raspbin-buster-lite.img (about 1.8GB). 

    Copy the img file to an 8GB SDcard using dd on linux or Win32DiskImager
    on Windows.

    Insert the card into the Pi, attach monitor, keyboard, and ethernet, then
    apply power (the ethernet must provide DHCP and internet access).

    Wait for Pi to boot to login prompt, log in as user 'pi' with password
    'raspberry'
    
    Run:

        sudo passwd pi -- enter a new password (twice)

        sudo systemctl enable ssh
    
        sudo apt update -- answer 'yes' if requested

        sudo apt -y upgrade

        sudo apt -y install git
        
        git clone https://github.com/glitchub/rasping

    Edit rasping/rasping.conf as desired, then run:
    
        sudo rasping/install.sh

The gateway is now ready to go, attach a usb ethernet dongle and reboot.        
