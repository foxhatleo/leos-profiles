# Check if thefuck is installed
if type -q thefuck
    eval (thefuck --alias | string split0)
else
    if not test -f $HOME/.lp-nofuck
        echo "thefuck is not installed. To silence, touch \$HOME/.lp-nofuck." >&2
    end
end
