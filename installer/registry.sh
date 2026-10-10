#!/usr/bin/env bash
# shellcheck disable=SC2034  # ARTIFACT_* are read by the sourcing modules
# Ordered component registry. Columns: name | component dependencies | package
# groups | install handler. Verification and signature handlers use name->_.
#
# A package group is implied only when the component needs its members:
# rpatool runs on python3, pyenv/rbenv compile against dev-tools, and the
# shell components need zsh. Bun, fnm, Yarn and pnpm are self-contained
# (Yarn/pnpm run on fnm's Node), so they imply no OS runtimes (MI-4).
component_registry() {
  cat <<'ROWS'
packages|||install_os_packages
bins|packages|python|install_local_bins
pyenv|packages|dev-tools|install_pyenv
rbenv|packages|dev-tools|install_rbenv
bun|packages||install_bun
fnm|packages||install_fnm
yarn|fnm,packages||install_yarn
pnpm|fnm,packages||install_pnpm
uv|packages||install_uv
plugins|packages|shell|install_prompt_plugins
fonts|||install_fonts
zsh-config|packages|shell|install_zsh_config
default-shell|packages|shell|set_default_shell
ROWS
}
CANONICAL_STEPS=$(component_registry | awk -F '|' '{printf "%s%s", sep, $1; sep=","}')
readonly CANONICAL_STEPS

# component_handler <component> <install|verify|signature|artifacts>: the
# handler function name, or for `artifacts` the names of the direct locked
# artifacts the component owns (from artifact_registry below), one per line.
component_handler() {
  local name=$1 kind=$2 step dependencies groups installer artifact owner rest
  while IFS='|' read -r step dependencies groups installer; do
    [[ $step == "$name" ]] || continue
    case $kind in
      install) printf '%s\n' "$installer" ;;
      verify|signature) printf '%s_%s\n' "$kind" "${step//-/_}" ;;
      artifacts)
        while IFS='|' read -r artifact owner rest; do
          [[ $owner != "$step" ]] || printf '%s\n' "$artifact"
        done < <(artifact_registry) ;;
      *) die "Unknown component handler kind: $kind" ;;
    esac
    return 0
  done < <(component_registry)
  die "Unknown component: $name"
}

validate_component_registry() {
  local step dependencies groups installer kind handler item preceding="" name
  local -a items=()
  valid_csv "$CANONICAL_STEPS" "$CANONICAL_STEPS" || die "Duplicate component registration"
  while IFS= read -r name; do
    artifact_row "$name"
    has_csv_item "$CANONICAL_STEPS" "$ARTIFACT_COMPONENT" || die "Artifact $name has unknown component $ARTIFACT_COMPONENT"
    [[ -n $ARTIFACT_EXECUTABLES ]] || die "Artifact $name installs no executable"
    case $ARTIFACT_ARCHIVE in
      file|zip|tar.gz) ;;
      *) die "Artifact $name has an unsupported archive kind: $ARTIFACT_ARCHIVE" ;;
    esac
  done < <(artifact_names)
  while IFS='|' read -r step dependencies groups installer; do
    for kind in install verify signature; do
      handler=$(component_handler "$step" "$kind")
      declare -F "$handler" >/dev/null || die "$step has no $kind handler: $handler"
    done
    csv_split items "$dependencies"
    for item in ${items[@]+"${items[@]}"}; do
      has_csv_item "$CANONICAL_STEPS" "$item" || die "$step has unknown dependency $item"
      has_csv_item "$preceding" "$item" || die "$item must precede $step in the component registry"
    done
    csv_split items "$groups"
    for item in ${items[@]+"${items[@]}"}; do
      has_csv_item "$CANONICAL_GROUPS" "$item" || die "$step has unknown package group $item"
    done
    preceding="${preceding:+$preceding,}$step"
  done < <(component_registry)
}

normalise_dependencies() {
  local previous step dependencies groups installer item
  local -a items=()
  [[ -z $SELECTED_GROUPS ]] || add_csv_item SELECTED_STEPS packages
  # Fixed point: transitive dependencies must work regardless of table order.
  while :; do
    previous=$SELECTED_STEPS
    while IFS='|' read -r step dependencies groups installer; do
      has_csv_item "$SELECTED_STEPS" "$step" || continue
      csv_split items "$dependencies"
      for item in ${items[@]+"${items[@]}"}; do add_csv_item SELECTED_STEPS "$item"; done
      csv_split items "$groups"
      for item in ${items[@]+"${items[@]}"}; do add_csv_item SELECTED_GROUPS "$item"; done
    done < <(component_registry)
    [[ $previous != "$SELECTED_STEPS" ]] || break
  done
}

# Direct locked artifacts: executables downloaded from a pinned URL, verified
# by SHA-256 and installed into ~/.local/bin. Columns: name | owning component
# | lock prefix | archive (zip, tar.gz, or `file` for a single verified file)
# | installed executables (space-separated; the first is the main one) |
# expected first line of `<main> --version`, with %s for <PREFIX>_VERSION
# (empty: verified by digest instead).
#
# This one table drives each artifact's lock lookup, install, verification,
# signature and inspect record (CQ-8); the owning component's handlers call
# artifact_install, artifact_verify and artifact_signature. The lock prefix
# names installer/lock.sh values: <PREFIX>_VERSION and, for this platform, the
# first URL/SHA256 pair defined among <PREFIX>_<DARWIN|LINUX>_<AARCH64|X64>,
# <PREFIX>_<DARWIN|LINUX> and <PREFIX>.
artifact_registry() {
  cat <<'ROWS'
rpatool|bins|RPATOOL|file|rpatool|
bun|bun|BUN|zip|bun|%s
fnm|fnm|FNM|zip|fnm|fnm %s
starship|plugins|STARSHIP|tar.gz|starship|starship %s
uv|uv|UV|tar.gz|uv uvx|uv %s
ROWS
}

# artifact_row <name>: sets ARTIFACT_COMPONENT, ARTIFACT_PREFIX,
# ARTIFACT_ARCHIVE, ARTIFACT_EXECUTABLES and ARTIFACT_VERSION_LINE.
artifact_row() {
  local name=$1 row_name component prefix archive executables version_line
  while IFS='|' read -r row_name component prefix archive executables version_line; do
    [[ $row_name == "$name" ]] || continue
    ARTIFACT_COMPONENT=$component
    ARTIFACT_PREFIX=$prefix
    ARTIFACT_ARCHIVE=$archive
    ARTIFACT_EXECUTABLES=$executables
    ARTIFACT_VERSION_LINE=$version_line
    return 0
  done < <(artifact_registry)
  die "Unknown locked artifact: $name"
}

# artifact_names: every registered artifact, in table order.
artifact_names() {
  local name rest
  while IFS='|' read -r name rest; do
    printf '%s\n' "$name"
  done < <(artifact_registry)
}

# artifact_asset <name>: print "<url><TAB><sha256>" for this platform, or
# return 1 when the lock has none (an unsupported platform).
artifact_asset() {
  local os arch candidate url_var sha_var
  artifact_row "$1"
  if [[ $OS_FAMILY == macos ]]; then os=DARWIN; else os=LINUX; fi
  case $(uname -m) in
    arm64|aarch64) arch=AARCH64 ;;
    x86_64|amd64) arch=X64 ;;
    *) arch=UNSUPPORTED ;;
  esac
  for candidate in "${ARTIFACT_PREFIX}_${os}_${arch}" "${ARTIFACT_PREFIX}_${os}" "$ARTIFACT_PREFIX"; do
    url_var=${candidate}_URL
    sha_var=${candidate}_SHA256
    [[ -n ${!url_var-} ]] || continue
    [[ -n ${!sha_var-} ]] || die "$url_var has no matching $sha_var in installer/lock.sh"
    printf '%s\t%s\n' "${!url_var}" "${!sha_var}"
    return 0
  done
  return 1
}

# artifact_version <name>: the locked version (empty for a versionless file).
artifact_version() {
  local version_var
  artifact_row "$1"
  version_var=${ARTIFACT_PREFIX}_VERSION
  printf '%s' "${!version_var-}"
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
