# Leo's Profiles
# Homebrew
#
# This script adds useful commands if Homebrew is present.

function __leos_brew_set_remote
    set -l repo_path "$argv[1]"
    set -l remote_url "$argv[2]"
    set -l repo_label "$argv[3]"

    if test -z "$repo_path"
        puts "Skipping $repo_label; repository path is unavailable."
        return 0
    end

    if command git -C "$repo_path" rev-parse --is-inside-work-tree > /dev/null 2>&1
        command git -C "$repo_path" remote set-url origin "$remote_url"
        return $status
    end

    puts "Skipping $repo_label; local git clone is not present."
    return 0
end

if set -l brew_bin (__leos_brew_bin)
    # Set up Homebrew environment
    set -l brew_bindir (dirname "$brew_bin")
    add-path "$brew_bindir"
    eval ("$brew_bin" shellenv)

    if test -f "$HOME/.brew-china"
        set -gx HOMEBREW_BOTTLE_DOMAIN "https://mirrors.ustc.edu.cn/homebrew-bottles"
    end

    function brew-checkup
        brew update
        brew upgrade
        brew upgrade --cask
        brew cleanup -s
        # brew doctor can be uncommented if needed
        # brew doctor
    end

    function brew-china-enable
        set -l brew_repo (brew --repo)
        set -l core_repo (brew --repository homebrew/core)
        set -l cask_repo (brew --repository homebrew/cask)

        __leos_brew_set_remote "$brew_repo" https://mirrors.ustc.edu.cn/brew.git "Homebrew/brew"; or return 1
        __leos_brew_set_remote "$core_repo" https://mirrors.ustc.edu.cn/homebrew-core.git "homebrew/core"; or return 1
        __leos_brew_set_remote "$cask_repo" https://mirrors.ustc.edu.cn/homebrew-cask.git "homebrew/cask"; or return 1

        touch "$HOME/.brew-china"
        set -gx HOMEBREW_BOTTLE_DOMAIN "https://mirrors.ustc.edu.cn/homebrew-bottles"
        brew update
    end

    function brew-china-disable
        set -l brew_repo (brew --repo)
        set -l core_repo (brew --repository homebrew/core)
        set -l cask_repo (brew --repository homebrew/cask)

        __leos_brew_set_remote "$brew_repo" https://github.com/Homebrew/brew.git "Homebrew/brew"; or return 1
        __leos_brew_set_remote "$core_repo" https://github.com/Homebrew/homebrew-core.git "homebrew/core"; or return 1
        __leos_brew_set_remote "$cask_repo" https://github.com/Homebrew/homebrew-cask.git "homebrew/cask"; or return 1

        rm -f "$HOME/.brew-china"
        set -e HOMEBREW_BOTTLE_DOMAIN
        brew update
    end

else
    if test (uname -s) = 'Darwin'; and not test -f $HOME/.lp-nobrew
        puts-err "brew is not installed. To silence, touch \$HOME/.lp-nobrew."
    end
end
