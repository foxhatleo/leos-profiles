# Leo's Profiles
# APT
#
# This script adds useful commands if apt-get is present.

if type -q apt-get
    function apt-checkup
        # DEBIAN_FRONTEND must be set on the sudo command line: sudo's env_reset
        # strips it from the parent shell's environment otherwise. This keeps the
        # already-unattended (-y) checkup from stalling on dpkg/debconf prompts.
        sudo DEBIAN_FRONTEND=noninteractive apt update -y
        sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y
        sudo DEBIAN_FRONTEND=noninteractive apt autoremove --purge -y
        sudo DEBIAN_FRONTEND=noninteractive apt clean -y
    end
end
