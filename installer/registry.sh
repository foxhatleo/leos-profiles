#!/usr/bin/env bash
# Ordered component registry. Columns: name | component dependencies | package
# groups | install handler. Verification and signature handlers use name->_.
component_registry() {
  cat <<'ROWS'
packages|||install_os_packages
bins|packages|languages|install_local_bins
pyenv|packages|dev-tools|install_pyenv
rbenv|packages|dev-tools|install_rbenv
bun|packages|languages|install_bun
fnm|packages|languages|install_fnm
yarn|fnm,packages|languages|install_yarn
pnpm|fnm,packages|languages|install_pnpm
plugins|packages|shell|install_prompt_plugins
fonts|||install_fonts
zsh-config|packages|shell|install_zsh_config
default-shell|packages|shell|set_default_shell
ROWS
}
CANONICAL_STEPS=$(component_registry | awk -F '|' '{printf "%s%s", sep, $1; sep=","}')
readonly CANONICAL_STEPS

component_handler() {
  local name=$1 kind=$2 step dependencies groups installer
  while IFS='|' read -r step dependencies groups installer; do
    [[ $step == "$name" ]] || continue
    case $kind in
      install) printf '%s\n' "$installer" ;;
      verify|signature) printf '%s_%s\n' "$kind" "${step//-/_}" ;;
      *) die "Unknown component handler kind: $kind" ;;
    esac
    return 0
  done < <(component_registry)
  die "Unknown component: $name"
}

validate_component_registry() {
  local step dependencies groups installer kind handler item preceding=""
  valid_csv "$CANONICAL_STEPS" "$CANONICAL_STEPS" || die "Duplicate component registration"
  while IFS='|' read -r step dependencies groups installer; do
    for kind in install verify signature; do
      handler=$(component_handler "$step" "$kind")
      declare -F "$handler" >/dev/null || die "$step has no $kind handler: $handler"
    done
    local IFS=,
    for item in $dependencies; do
      has_csv_item "$CANONICAL_STEPS" "$item" || die "$step has unknown dependency $item"
      has_csv_item "$preceding" "$item" || die "$item must precede $step in the component registry"
    done
    for item in $groups; do
      has_csv_item "$CANONICAL_GROUPS" "$item" || die "$step has unknown package group $item"
    done
    preceding="${preceding:+$preceding,}$step"
  done < <(component_registry)
}

normalise_dependencies() {
  local previous step dependencies groups installer item
  [[ -z $SELECTED_GROUPS ]] || add_csv_item SELECTED_STEPS packages
  # Fixed point: transitive dependencies must work regardless of table order.
  while :; do
    previous=$SELECTED_STEPS
    while IFS='|' read -r step dependencies groups installer; do
      has_csv_item "$SELECTED_STEPS" "$step" || continue
      local IFS=,
      for item in $dependencies; do add_csv_item SELECTED_STEPS "$item"; done
      for item in $groups; do add_csv_item SELECTED_GROUPS "$item"; done
    done < <(component_registry)
    [[ $previous != "$SELECTED_STEPS" ]] || break
  done
}

verify_step() {
  local handler
  handler=$(component_handler "$1" verify) || return 1
  "$handler"
}

step_signature() {
  local handler
  handler=$(component_handler "$1" signature)
  { printf 'state-v3|%s|%s' "$OS_FAMILY" "$1"; "$handler"; } | hash_text
}

install_prompt_plugins() { install_starship; install_plugins; }
