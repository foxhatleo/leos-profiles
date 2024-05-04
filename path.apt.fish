# Leo's Profiles
# APT
#
# This script adds useful commands if apt-get is present.

if type -q apt-get
    function apt-checkup
        sudo apt update -y
        sudo apt upgrade -y
        sudo apt autoremove --purge -y
        sudo apt clean -y
    end
end
