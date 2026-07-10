# Go (GOPATH may contain multiple colon-separated workspaces).
if command -v go >/dev/null 2>&1; then
  _leos_gopath=$(go env GOPATH 2>/dev/null)
  for _leos_go_workspace in ${(s.:.)_leos_gopath}; do
    add-path "$_leos_go_workspace/bin"
  done
  unset _leos_gopath _leos_go_workspace
fi

:
