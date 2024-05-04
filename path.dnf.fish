# Leo's Profiles
# DNF
#
# This script adds useful commands if dnf is present.

if type -q dnf
    function dnf-checkup
        sudo dnf update -y
        sudo dnf autoremove -y
        sudo dnf clean all -y
    end
end
