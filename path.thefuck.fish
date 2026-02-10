# Check if thefuck is installed
if type -q thefuck
    eval (thefuck --alias | string split0)
end
