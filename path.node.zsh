if type "yarn" > /dev/null && [[ ":$PATH:" != *":$(yarn global bin):"* ]]; then
  add-path "$(yarn global bin)" required;
fi