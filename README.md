Rasping - Raspberry Pi NAT Gateway

Configure a Raspberry Pi 3B/4 as a NAT gateway.

The Pi attaches to WAN via ethernet or wifi STA, and provides LAN connectivity
via ethernet, wifi AP, or usb ethernet dongles. 

Please see rasping.cfg for detailed configuration information.

To install:

    Download a current raspian lite image:
        
        wget https://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2019-06-24/2019-06-20-raspbian-buster-lite.zip

    Unzip and extract the img file, it will be about about 1.8GB. 

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

The monitor and keyboard can be disconnected. The Pi will boot into network
gateway mode automatically.
