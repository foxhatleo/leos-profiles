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
# handler function name, or for `artifacts` the names of the tool artifacts
# the component owns (from artifact_registry below), one per line.
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
      file) ;;
      zip|tar.gz)
        [[ -n $ARTIFACT_FORMULA ]] || die "Artifact $name has no Homebrew formula"
        [[ $ARTIFACT_VERSION_LINE == *%s* ]] || die "Artifact $name has no version line" ;;
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

# Tool artifacts: executables the installer puts on PATH itself. Columns:
# name | owning component | source prefix | archive (zip, tar.gz, or `file`
# for a single pinned file) | installed executables (space-separated; the
# first is the main one) | first line of `<main> --version`, with %s for the
# version (empty: checked by digest instead) | Homebrew formula.
#
# This one table drives each artifact's install, verification, signature and
# inspect record (CQ-8); the owning component's handlers call
# artifact_install, artifact_verify and artifact_signature. Where it comes
# from depends on the platform (artifact_source):
#   formula  macOS: Homebrew installs the formula, and `brew upgrade` keeps it
#            current.
#   release  Linux: the latest GitHub release of <PREFIX>_REPOSITORY, asset
#            <PREFIX>_LINUX_<AARCH64|X64>_ASSET from installer/sources.sh,
#            installed into ~/.local/bin.
#   pinned   `file` artifacts, everywhere: <PREFIX>_URL, checked against
#            <PREFIX>_SHA256.
artifact_registry() {
  cat <<'ROWS'
rpatool|bins|RPATOOL|file|rpatool||
bun|bun|BUN|zip|bun|%s|bun
fnm|fnm|FNM|zip|fnm|fnm %s|fnm
starship|plugins|STARSHIP|tar.gz|starship|starship %s|starship
uv|uv|UV|tar.gz|uv uvx|uv %s|uv
ROWS
}

# artifact_row <name>: sets ARTIFACT_COMPONENT, ARTIFACT_PREFIX,
# ARTIFACT_ARCHIVE, ARTIFACT_EXECUTABLES, ARTIFACT_VERSION_LINE and
# ARTIFACT_FORMULA.
artifact_row() {
  local name=$1 row_name component prefix archive executables version_line formula
  while IFS='|' read -r row_name component prefix archive executables version_line formula; do
    [[ $row_name == "$name" ]] || continue
    ARTIFACT_COMPONENT=$component
    ARTIFACT_PREFIX=$prefix
    ARTIFACT_ARCHIVE=$archive
    ARTIFACT_EXECUTABLES=$executables
    ARTIFACT_VERSION_LINE=$version_line
    ARTIFACT_FORMULA=$formula
    return 0
  done < <(artifact_registry)
  die "Unknown artifact: $name"
}

# artifact_names: every registered artifact, in table order.
artifact_names() {
  local name rest
  while IFS='|' read -r name rest; do
    printf '%s\n' "$name"
  done < <(artifact_registry)
}

# artifact_source <name>: formula, release or pinned (see artifact_registry).
artifact_source() {
  artifact_row "$1"
  if [[ $ARTIFACT_ARCHIVE == file ]]; then
    printf 'pinned\n'
  elif [[ $OS_FAMILY == macos ]]; then
    printf 'formula\n'
  else
    printf 'release\n'
  fi
}

# artifact_pinned_asset <name>: "<url><TAB><sha256>" of a pinned artifact.
artifact_pinned_asset() {
  local url_var sha_var
  artifact_row "$1"
  url_var=${ARTIFACT_PREFIX}_URL
  sha_var=${ARTIFACT_PREFIX}_SHA256
  [[ -n ${!url_var-} && -n ${!sha_var-} ]] || die "$1 needs $url_var and $sha_var in installer/sources.sh"
  printf '%s\t%s\n' "${!url_var}" "${!sha_var}"
}

# artifact_release_asset <name>: "<owner/repo><TAB><asset>" for this Linux
# CPU, or return 1 when upstream publishes no build for it.
artifact_release_asset() {
  local arch repository_var asset_var
  artifact_row "$1"
  case $(uname -m) in
    arm64|aarch64) arch=AARCH64 ;;
    x86_64|amd64) arch=X64 ;;
    *) return 1 ;;
  esac
  repository_var=${ARTIFACT_PREFIX}_REPOSITORY
  asset_var=${ARTIFACT_PREFIX}_LINUX_${arch}_ASSET
  [[ -n ${!asset_var-} ]] || return 1
  [[ -n ${!repository_var-} ]] || die "$1 needs $repository_var in installer/sources.sh"
  printf '%s\t%s\n' "${!repository_var}" "${!asset_var}"
}

# step_follows_upstream <step>: a full upgrade re-runs it to move it forward:
# packages, and the components that track a latest release or default branch.
# bins (a pinned file) and fonts stay as installed.
step_follows_upstream() {
  case $1 in
    packages|pyenv|rbenv|bun|fnm|yarn|pnpm|uv|plugins) return 0 ;;
    *) return 1 ;;
  esac
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
