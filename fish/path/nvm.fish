# Leo's Profiles
# nvm
#
# This script adds support for nvm.

if not functions -q __nvm_original_fish_prompt
    if functions -q fish_prompt
        functions -c fish_prompt __nvm_original_fish_prompt
    else
        function __nvm_original_fish_prompt
        end
    end
end

function __leos_nvm_sync
    if not functions -q nvm
        return
    end

    if set -l nvmrc (_nvm_find_up $PWD .nvmrc)
        nvm use > /dev/null 2>&1; or true
    else if set -l nodever (_nvm_find_up $PWD .node-version)
        nvm use > /dev/null 2>&1; or true
    else if set -q nvm_default_version
        nvm use --silent $nvm_default_version > /dev/null 2>&1; or true
    end

    if set -q nvm_current_version
        set -l nvm_bin $nvm_data/$nvm_current_version/bin
        if set -q fish_user_paths
            while contains -- $nvm_bin $fish_user_paths
                set -e fish_user_paths[(contains -i -- $nvm_bin $fish_user_paths)]
            end
            set -g fish_user_paths $nvm_bin $fish_user_paths
        else
            set -g fish_user_paths $nvm_bin
        end
    end
end

# Re-apply the appropriate nvm version after other PATH setup has run.
__leos_nvm_sync

function fish_prompt
    __leos_nvm_sync
    __nvm_original_fish_prompt
end
