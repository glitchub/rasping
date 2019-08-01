Rasping - Raspberry Pi NAT Gateway

Configure a Raspberry PI 3 or equivalent as a ethernet NAT gateway.

Physical configuration:

    The Pi's ethernet interface connects to the WAN. By default it expects to
    receive an address via DHCP, but can also be configiured to use static IP.

    The PI provides a LAN gateway on usb ethernet dongle, if attached, and via
    Wifi if enabled.  The gateway has a pre-defined static IP address. By
    default, DHCP is served to the upper-half of the LAN IP range, the lower
    half is not assigned and available for arbitrary static IP. The LAN also
    provides DNS.

To install:

    Download the SDcard image:
        
        wget https://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2019-06-24/2019-06-20-raspbian-buster-lite.zip

    Unzip and extract file 2019-06-20-raspbin-buster-lite.img (about 1.8GB). 

    Copy the img file to an 8GB SDcard using dd on linux or Win32DiskImager
    on Windows, etc.

    Insert the card into the Pi, attach monitor, keyboard, and ethernet, then
    apply power (the ethernet must provide DHCP and internet access).

    Wait for Pi to boot to login prompt. The default user is 'pi' with password
    'raspberry'. Enter the following commands:

        sudo systemctl enable ssh                           -- if SSH access is desired
        
        sudo raspi-config nonint do_configure_keyboard us   -- if you want to edit files from the Pi console (and your keyboard is 'us')
        
        sudo passwd pi                                      -- enter a new password 

        sudo apt -y update                                      

        sudo apt -y upgrade                                 -- this may take a while    
        
        sudo apt -y install git                                     
        
        git clone https://github.com/glitchub/rasping

        sudo reboot                                             
   
    Wait for reboot, then log back in (with the new password) and perform:

        nano rasping/rasping.cfg                            -- edit the configuration as desired

        make -C rasping                                     -- wait for "INSTALL COMPLETE"

        sudo reboot

The system will boot into the network gateway mode automatically. If you didn't
enable wifi in the Makefile then you'll need to attach a usb ethernet dongle
and attach to that.         
