Rasping - Raspberry Pi NAT Gateway

Configure a Raspberry Pi 3 or 4 as a NAT gateway, in one of three basic
configurations:

    Wired WAN and wired LAN via USB ethernet dongle(s)

    Wired WAN and wireless LAN (and optional dongles)

    Wireless WAN and wired LAN via built-in ethernet (and optional dongles)

To install:

    Download a current Raspian Lite image:

        wget https://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2019-07-12/2019-07-10-raspbian-buster-lite.zip

    Unzip and extract the img file, it will be about 2GB.

    Using a PC, copy the img file to an 8GB SDcard with dd on linux/darwin or
    Win32DiskImager on Windows.

    To log in via SSH:

        Remove and reinstall the SDcard into the PC so it re-reads the
        partition table.

        A Windows machine should mount the boot partition automatically, on
        Linux you'll need to manually mount it (the first partition, eg
        /dev/sdb1 or /dev/mmcblk0p1, etc).

        Ccreate an empty file named 'ssh' in the boot partition.

        Unmount and insert the SD card into the Pi, attach it to local
        ethernet, then apply power.

        On the PC, run the python script "sscan" (incldued in this repo) to
        list all open ssh ports on the local subnet. The Pi will appear as
        something like:

            192.168.1.144 : SSH-2.0-OpenSSH_7.9p1 Raspbian-10

        Since it can take a minute or so for the Pi to boot, you'll have to run
        sscan several times.

        Once the IP address has been detected, just "ssh pi@ip.ad.re.ss" from your
        PC, with password "raspberry".

        Be aware that the 'ssh' file will be automatically deleted, so if you
        lose power you'll have to recreate the empty file.

    To log in via text console:

        Insert the SD card into the Pi, attach HDMI monitor, keyboard and ethernet,
        then apply power.

        When the login prompt appears, log in as "pi" with password "raspberry".

        Note the default keyboard mapping is for UK keyboards. If you have a
        different layout, first enter the command:

            sudo raspi-config nonint do_configure_board US

        Replace "US" with the desired ISO-3116 country code (see the Wikipedia page for a list).

    Now enter the following commands:

        sudo systemctl enable ssh        -- permanently enable ssh

        passwd                           -- set a new password

        sudo apt update                  -- download latest package metadata

        sudo apt -y upgrade              -- download and install updated packages, this may take a while

        sudo reboot

    Log back into the Pi again, as described above (but with the new
    password). Then enter the following:

        sudo apt -y install git

        git clone https://github.com/glitchub/rasping

    At this point you 'll have a "rasping" directory containing this repo.  The
    file "rasping.cfg" defines all configurable parameters, and provides a
    detailed description of each.

        nano rasping/rasping.cfg         -- edit the configuration as desired

        make -C rasping                  -- wait for "INSTALL COMPLETE"

        sudo reboot

The Pi will boot into NAT gateway mode automatically.

Depending on configuration you may need to unplug the ethernet from the network
and attach USB ethernet dongles.

The monitor and keyboard can be detached.

You'll be able to ssh to the LAN_IP from any LAN port, and also from WAN if you
unblocked it.

