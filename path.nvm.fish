# Leo's Profiles
# nvm
#
# This script adds support for nvm.

functions -c fish_prompt __nvm_original_fish_prompt

function fish_prompt
    nvm use > /dev/null 2>&1; or true
    __nvm_original_fish_prompt
end
