Rasping - Raspberry Pi NAT Gateway

Configure a Raspberry Pi 3B/B+/4 as a NAT gateway, in one of three basic
configurations:

    Wired WAN via built-in ethernet, and wired LAN via USB ethernet dongle(s)

    Wired WAN via built-in ethernet and wireless LAN (also optional dongles)

    Wireless WAN and wired LAN via built-in ethernet (also optional dongles)

To install, first download a current Raspian Lite image:

        wget https://downloads.raspberrypi.org/raspbian_lite/images/raspbian_lite-2019-07-12/2019-07-10-raspbian-buster-lite.zip

Unzip and extract the img file, it will be about 2GB.

Optional: on a linux PC you can alter the image now so ssh will start on the
first boot:

            mkdir xxx
            sudo mount -oloop,offset=4096K /path/to/the.img xxx
            sudo touch xxx/ssh
            sudo umount xxx

Copy the img file to an 8GB SDcard with dd on linux/darwin or Win32DiskImager
on Windows.

To log in via SSH:

        If you did not perform the "touch x/ssh" operation above then:

            Remove and reinstall the SDcard into the PC so it re-reads the
            partition table.

        Windows should mount the boot partition automatically, on Linux you may
        need to mount it manually, it's the first partition i.e.  /dev/sdb1 or
        /dev/mmcblk0p1, etc). The correct directory will contain about 20 files
        including config.txt.

            Create an empty file named "ssh" in the boot partition.

            Unmount the partition before removing the SD card from the PC.

        Insert the SD card into the Pi, attach it to local ethernet, then apply
        power.

    On the PC, run the python script "sscan" (included in this repo) to list
    all open ssh ports on the local subnet. The Pi will appear as something
    like:

            192.168.1.144 : SSH-2.0-OpenSSH_7.9p1 Raspbian-10

        It will take a minute or so for the Pi to boot, just run sscan repeatedly
        until it shows up.

        Once the IP address has been detected, you can "ssh pi@ip.ad.re.ss" on your
        PC and log in with password "raspberry".

    Be aware that the magic "ssh" file will only work once. If the Pi resets
    for some reason before you"ve reached the "systemctl enable ssh" step below
    then you'll need to re-create the file.

To log in via text console:

        Insert the SD card into the Pi, attach HDMI monitor, keyboard and ethernet,
        then apply power.

        When the login prompt appears, log in as "pi" with password "raspberry".

    The default keyboard mapping is for UK keyboards. If you have a different
    layout you may have trouble editing files. Enter the command:

            sudo raspi-config nonint do_configure_board US

        Where US" is your desired ISO-3116 country code, see
        https://en.wikipedia.org/wiki/List_of_ISO_3166_country_codes

    Now that you're logged in, enter the following commands:

        sudo systemctl enable ssh        -- permanently enable ssh

        passwd                           -- set a new password

        sudo apt update                  -- download latest package metadata

        sudo apt -y upgrade              -- download and install updated packages, this will take a few minutes

        sudo reboot

    Log back into the Pi with your new password and enter the following:

        sudo apt -y install git

        git clone https://github.com/glitchub/rasping

    At this point the Pi will have a "rasping" directory containing this repo.
    The file "rasping.cfg" defines all configurable parameters, and provides a
    detailed description of each.

        cd rasping

        nano rasping.cfg                -- edit the configuration as desired

        make

    The make process will install packages, rewrite system files, and perform a
    bunch if systemctl operations. When it's done you'll see "INSTALL COMPLETE".

    Reboot the Pi and it will come up in NAT gateway mode automatically.

    You'll be able to ssh to the Pi from any LAN device (to the LAN_IP
    address), and also from the WAN if you UNBLOCKed port 22.

    You can make changes to the config file and install them with "make",
    followed by reboot.

    You can also reve the original network configuration with "make
    uninstall", followed by reboot.
