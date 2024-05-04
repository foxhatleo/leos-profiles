# Leo's Profiles
# Homebrew
#
# This script adds useful commands if Homebrew is present.

if command -v brew > /dev/null 2>&1
    # Set up Homebrew environment
    add-path "/opt/homebrew/bin"
    eval (brew shellenv)
    
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
        git -C (brew --repo) remote set-url origin https://mirrors.ustc.edu.cn/brew.git
        git -C (brew --repo)/Library/Taps/homebrew/homebrew-core remote set-url origin https://mirrors.ustc.edu.cn/homebrew-core.git
        git -C (brew --repo)/Library/Taps/homebrew/homebrew-cask remote set-url origin https://mirrors.ustc.edu.cn/homebrew-cask.git
        touch "$HOME/.brew-china"
        set -gx HOMEBREW_BOTTLE_DOMAIN "https://mirrors.ustc.edu.cn/homebrew-bottles"
        brew update
    end

    function brew-china-disable
        git -C (brew --repo) remote set-url origin https://github.com/Homebrew/brew.git
        git -C (brew --repo)/Library/Taps/homebrew/homebrew-core remote set-url origin https://github.com/Homebrew/homebrew-core.git
        git -C (brew --repo)/Library/Taps/homebrew/homebrew-cask remote set-url origin https://github.com/Homebrew/homebrew-cask.git
        rm -f "$HOME/.brew-china"
        set -e HOMEBREW_BOTTLE_DOMAIN
        brew update
    end
    
else
    if string match -q "darwin*" -- $OSTYPE; and not test -f $HOME/.lp-nobrew
        # Error function must be defined in fish, or you can use a simple echo with color here.
        echo (set_color red) "brew is not installed. To silence, touch \$HOME/.lp-nobrew." (set_color normal)
    end
end
