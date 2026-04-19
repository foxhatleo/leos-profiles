# Leo's Profiles
# Go
#
# This script adds go path if it exists.

if type -q go
    add-path "$(go env GOPATH)/bin"
end