#!/usr/bin/env bash
# Sourced by install.sh; shares the installer context.
# shellcheck disable=SC2034

github_repo_slug() {
  local url=$1 slug
  case $url in
    https://github.com/*) slug=${url#https://github.com/} ;;
    git@github.com:*) slug=${url#git@github.com:} ;;
    ssh://git@github.com/*) slug=${url#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac
  slug=${slug%/}
  slug=${slug%.git}
  [[ $slug == */* && $slug != */*/* ]] || return 1
  printf '%s\n' "$slug" | tr '[:upper:]' '[:lower:]'
}

github_origins_equivalent() {
  local actual expected actual_slug expected_slug
  actual=$1
  expected=$2
  actual_slug=$(github_repo_slug "$actual") || return 1
  expected_slug=$(github_repo_slug "$expected") || return 1
  [[ $actual_slug == "$expected_slug" ]]
}

clone_pinned() {
  local repository=$1 commit=$2 destination=$3 label=$4 origin
  if [[ -d $destination ]]; then
    [[ -d $destination/.git ]] || die "$label exists but is not a Git checkout: $destination"
    origin=$(git -C "$destination" remote get-url origin 2>/dev/null || true)
    github_origins_equivalent "$origin" "$repository" || die "$label checkout has an unexpected origin: $destination"
    [[ -z $(git -C "$destination" status --porcelain) ]] || die "$label checkout has local changes: $destination"
    if [[ $origin != "$repository" ]]; then
      run git -C "$destination" remote set-url origin "$repository"
    fi
  else
    run mkdir -p "$(dirname -- "$destination")"
    run git clone "$repository" "$destination"
  fi
  if [[ $DRY_RUN -eq 0 ]] && ! git -C "$destination" cat-file -e "$commit^{commit}" 2>/dev/null; then
    run git -C "$destination" fetch --depth 1 origin "$commit"
  fi
  run git -C "$destination" checkout --detach "$commit"
  [[ $DRY_RUN -eq 1 ]] || [[ $(git -C "$destination" rev-parse HEAD) == "$commit" ]] || die "$label did not resolve pinned commit"
}

install_local_bins() { artifact_install rpatool; }

# pyenv and rbenv ship an optional native extension that speeds up their
# bash code. Both work without it, so a failed compile only warns (BP-10).
compile_optional_extension() {
  local root=$1 label=$2
  [[ $DRY_RUN -eq 0 && -x $root/src/configure ]] || return 0
  if ! (cd "$root" && src/configure && make -C src); then
    warn "$label's optional native extension did not compile; $label works without it, a little slower."
  fi
}

install_pyenv() {
  clone_pinned "$PYENV_REPOSITORY" "$PYENV_COMMIT" "$HOME/.pyenv" pyenv
  compile_optional_extension "$HOME/.pyenv" pyenv
}

install_rbenv() {
  clone_pinned "$RBENV_REPOSITORY" "$RBENV_COMMIT" "$HOME/.rbenv" rbenv
  clone_pinned "$RUBY_BUILD_REPOSITORY" "$RUBY_BUILD_COMMIT" "$HOME/.rbenv/plugins/ruby-build" ruby-build
  compile_optional_extension "$HOME/.rbenv" rbenv
}

install_plugins() {
  local directory="$TARGET/zsh/plugins"
  clone_pinned "$ZSH_AUTOSUGGESTIONS_REPOSITORY" "$ZSH_AUTOSUGGESTIONS_COMMIT" "$directory/zsh-autosuggestions" zsh-autosuggestions
  clone_pinned "$ZSH_SYNTAX_HIGHLIGHTING_REPOSITORY" "$ZSH_SYNTAX_HIGHLIGHTING_COMMIT" "$directory/zsh-syntax-highlighting" zsh-syntax-highlighting
  clone_pinned "$ZSH_COMPLETIONS_REPOSITORY" "$ZSH_COMPLETIONS_COMMIT" "$directory/zsh-completions" zsh-completions
  clone_pinned "$FZF_TAB_REPOSITORY" "$FZF_TAB_COMMIT" "$directory/fzf-tab" fzf-tab
}

is_desktop() {
  [[ $OS_FAMILY == macos || -n ${DISPLAY:-}${WAYLAND_DISPLAY:-}${XDG_CURRENT_DESKTOP:-} ]]
}

font_should_install() {
  [[ $INSTALL_FONTS == yes ]] || { [[ $INSTALL_FONTS == auto ]] && is_desktop; }
}

# Where the fonts go, matching upstream's installer and font_is_installed:
# ~/Library/Fonts/NerdFonts on macOS (XDG_DATA_HOME is no font directory
# there), ${XDG_DATA_HOME:-~/.local/share}/fonts/NerdFonts on Linux.
nerd_font_directory() {
  if [[ $OS_FAMILY == macos ]]; then
    printf '%s\n' "$HOME/Library/Fonts/NerdFonts"
  else
    printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/fonts/NerdFonts"
  fi
}

# nerd_font_archive_digest <SHA-256.txt> <font>: print the digest the
# verified checksum list gives for <font>.tar.xz; fail for a name the release
# does not have. Lines are sha256sum's "<digest>  <file>".
nerd_font_archive_digest() {
  awk -v want="$2.tar.xz" '
    length($1) == 64 && $1 !~ /[^0-9A-Fa-f]/ {
      name = $NF
      sub(/^\*/, "", name)
      if (name == want) { print tolower($1); found = 1; exit }
    }
    END { exit !found }
  ' "$1"
}

# fetch_nerd_font_checksums <destination>: the release's SHA-256.txt, verified
# against its pinned digest. The URL and digest can be overridden for tests.
fetch_nerd_font_checksums() {
  download_verified "${NERD_FONTS_TEST_RELEASE_URL:-$NERD_FONTS_RELEASE_URL}/SHA-256.txt" \
    "${NERD_FONTS_TEST_CHECKSUMS_SHA256:-$NERD_FONTS_CHECKSUMS_SHA256}" "$1"
}

# require_known_nerd_font <SHA-256.txt> <font>: die, before any font download,
# when the release has no archive of that name.
require_known_nerd_font() {
  nerd_font_archive_digest "$1" "$2" >/dev/null ||
    die "Unknown Nerd Font: $2. Nerd Fonts $NERD_FONTS_VERSION has no $2.tar.xz; use a name from https://www.nerdfonts.com/font-downloads (for example JetBrainsMono)."
}

# install_nerd_font <font> [verified SHA-256.txt]: download the font's release
# archive, verify it against the checksum list and install its font files.
install_nerd_font() {
  local font=$1 checksums=${2:-} release=${NERD_FONTS_TEST_RELEASE_URL:-$NERD_FONTS_RELEASE_URL}
  local temp digest directory file found=0
  temp=$(mktemp -d)
  track_temp "$temp"
  if [[ -z $checksums ]]; then
    checksums="$temp/SHA-256.txt"
    fetch_nerd_font_checksums "$checksums"
  fi
  require_known_nerd_font "$checksums" "$font"
  digest=$(nerd_font_archive_digest "$checksums" "$font")
  download_verified "$release/$font.tar.xz" "$digest" "$temp/$font.tar.xz"
  mkdir -p "$temp/extract"
  tar -xJf "$temp/$font.tar.xz" -C "$temp/extract" || die "Could not extract $font.tar.xz (GNU tar needs xz)"
  directory=$(nerd_font_directory)
  mkdir -p "$directory"
  while IFS= read -r -d '' file; do
    install -m 644 "$file" "$directory/"
    found=1
  done < <(find "$temp/extract" -type f \( -iname '*.ttf' -o -iname '*.otf' \) -print0)
  (( found )) || die "Nerd Font archive $font.tar.xz contained no font files"
  if [[ $OS_FAMILY != macos ]] && command -v fc-cache >/dev/null 2>&1; then
    fc-cache -f "$directory" >/dev/null 2>&1 || warn "fc-cache could not refresh the font cache; log out and back in to see $font."
  fi
  rm -rf "$temp"
}

install_fonts() {
  if ! font_should_install; then
    say "Skipping Nerd Fonts ($INSTALL_FONTS policy)"
    return 0
  fi
  local font=${FONT_NAME:-JetBrainsMono}
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would download Nerd Fonts $NERD_FONTS_VERSION $font.tar.xz, verify it against the release's pinned SHA-256.txt and install it into $(nerd_font_directory)"
    return 0
  fi
  install_nerd_font "$font" "${NERD_FONTS_CHECKSUMS_FILE:-}"
}

ensure_user_npm_prefix() {
  local prefix="$HOME/.local/npm"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would prepare user-local npm prefix: $prefix"
    return 0
  fi
  mkdir -p "$prefix"
}

install_locked_npm_package() {
  local package=$1 url=$2 expected=$3 temp archive
  ensure_user_npm_prefix
  temp=$(mktemp -d)
  track_temp "$temp"
  archive="$temp/$package.tgz"
  download_verified "$url" "$expected" "$archive"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would install $package with the selected fnm Node runtime"
  else
    fnm_exec npm install --global --prefix "$HOME/.local/npm" "$archive"
  fi
  rm -rf "$temp"
}

install_yarn() {
  install_locked_npm_package yarn "$YARN_URL" "$YARN_SHA256"
  [[ $DRY_RUN -eq 1 ]] || fnm_exec "$HOME/.local/npm/bin/yarn" --version | grep -qx "$YARN_VERSION" || die "Yarn version verification failed"
}

install_pnpm() {
  install_locked_npm_package pnpm "$PNPM_URL" "$PNPM_SHA256"
  [[ $DRY_RUN -eq 1 ]] || fnm_exec "$HOME/.local/npm/bin/pnpm" --version | grep -qx "$PNPM_VERSION" || die "pnpm version verification failed"
}

machine_arch() {
  case $(uname -m) in
    arm64|aarch64) printf '%s\n' aarch64 ;;
    x86_64|amd64) printf '%s\n' x64 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

# platform_asset <artifact>: "<url><TAB><sha256>" for this platform, from the
# artifact registry's lock lookup; dies when the lock has none.
platform_asset() {
  artifact_asset "$1" || die "No locked $1 artifact for $OS_FAMILY/$(uname -m)"
}

# install_locked_archive_binary <tool> <zip|tar.gz> <destination> [extra...]:
# download the verified archive and install its <tool> executable at
# <destination>, and each extra executable beside it.
install_locked_archive_binary() {
  local tool=$1 extension=$2 destination=$3 url sha temp archive binary asset extra
  shift 3
  asset=$(platform_asset "$tool")
  IFS=$'\t' read -r url sha <<< "$asset"
  temp=$(mktemp -d)
  track_temp "$temp"
  archive="$temp/$tool.$extension"
  download_verified "$url" "$sha" "$archive"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would extract verified $tool to $destination"
    rmdir "$temp" 2>/dev/null || true
    return 0
  fi
  mkdir -p "$temp/extract"
  case $extension in
    zip) unzip -q "$archive" -d "$temp/extract" ;;
    tar.gz) tar -xzf "$archive" -C "$temp/extract" ;;
    *) die "Unsupported archive extension: $extension" ;;
  esac
  binary=$(find "$temp/extract" -type f -name "$tool" -print | sed -n '1p')
  [[ -n $binary ]] || die "Verified $tool archive did not contain its executable"
  mkdir -p "$(dirname -- "$destination")"
  install -m 755 "$binary" "$destination"
  for extra in ${1+"$@"}; do
    binary=$(find "$temp/extract" -type f -name "$extra" -print | sed -n '1p')
    [[ -n $binary ]] || die "Verified $tool archive did not contain $extra"
    install -m 755 "$binary" "$(dirname -- "$destination")/$extra"
  done
  rm -rf "$temp"
}

# artifact_version_ok <name> <executable>: the executable reports the locked
# version on the first line of --version (the registry's expected line,
# optionally followed by build details after a space).
artifact_version_ok() {
  local name=$1 executable=$2 expected first
  artifact_row "$name"
  # shellcheck disable=SC2059  # the registry column is the format
  printf -v expected "$ARTIFACT_VERSION_LINE" "$(artifact_version "$name")"
  first=$("$executable" --version 2>/dev/null | sed -n '1p') || return 1
  [[ $first == "$expected" || $first == "$expected "* ]]
}

# artifact_install <name> [directory]: install a registry artifact into
# ~/.local/bin (or the directory) and check the installed version.
artifact_install() {
  local name=$1 directory=${2:-$HOME/.local/bin} url sha main
  local -a executables=()
  artifact_row "$name"
  IFS=' ' read -r -a executables <<< "$ARTIFACT_EXECUTABLES"
  main=${executables[0]}
  if [[ $ARTIFACT_ARCHIVE == file ]]; then
    IFS=$'\t' read -r url sha <<< "$(platform_asset "$name")"
    download_verified "$url" "$sha" "$directory/$main"
    [[ $DRY_RUN -eq 1 ]] || chmod 700 "$directory/$main"
    return 0
  fi
  install_locked_archive_binary "$main" "$ARTIFACT_ARCHIVE" "$directory/$main" ${executables[1]+"${executables[@]:1}"}
  [[ $DRY_RUN -eq 1 ]] || artifact_version_ok "$name" "$directory/$main" || die "$name version verification failed"
}

# artifact_verify <name>: the installed copy in ~/.local/bin is the locked one:
# the same digest for a single file, or every executable present with the
# main one reporting the locked version.
artifact_verify() {
  local name=$1 directory="$HOME/.local/bin" executable asset url sha
  local -a executables=()
  artifact_row "$name"
  IFS=' ' read -r -a executables <<< "$ARTIFACT_EXECUTABLES"
  for executable in "${executables[@]}"; do
    [[ -x $directory/$executable ]] || return 1
  done
  if [[ $ARTIFACT_ARCHIVE == file ]]; then
    asset=$(artifact_asset "$name") || return 1
    IFS=$'\t' read -r url sha <<< "$asset"
    [[ $(sha256 "$directory/${executables[0]}") == "$sha" ]]
  else
    artifact_version_ok "$name" "$directory/${executables[0]}"
  fi
}

install_bun() { artifact_install bun; }

install_fnm() {
  artifact_install fnm
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would adopt a compatible existing Node into fnm, or install current LTS, and make it default"
    return 0
  fi
  resolve_node_version || die "Could not select a compatible Node version"
  eval "$("$HOME/.local/bin/fnm" env --shell bash)"
  run "$HOME/.local/bin/fnm" install "$RESOLVED_NODE_VERSION"
  run "$HOME/.local/bin/fnm" default "$RESOLVED_NODE_VERSION"
  run "$HOME/.local/bin/fnm" use "$RESOLVED_NODE_VERSION"
}

node_version_ok() { [[ ${1:-} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# The Node release index, from FNM_NODE_DIST_MIRROR when set (fnm honours the
# same variable for its downloads), so a mirror serves both (ONB-10). It must
# be an https URL.
node_dist_index_url() {
  local base=${FNM_NODE_DIST_MIRROR:-https://nodejs.org/dist}
  printf '%s/index.tab\n' "${base%/}"
}

resolve_node_lts() {
  [[ -z $RESOLVED_NODE_VERSION ]] || return 0
  local fnm_bin latest
  if command -v curl >/dev/null 2>&1; then
    # Timeouts matter here: this runs inside apply while the install lock is
    # held, and inside the otherwise read-only `inspect`, so a stalled
    # connection would hang the whole operation.
    # index.tab columns: $1 = version, $10 = the LTS codename ("-" when current).
    latest=$(curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
      --connect-timeout 15 --max-time 30 \
      "$(node_dist_index_url)" 2>/dev/null | awk -F '\t' 'NR > 1 && $10 != "-" { print $1; exit }') || true
  fi
  if ! node_version_ok "${latest:-}"; then
    if [[ -x $HOME/.local/bin/fnm ]]; then
      fnm_bin="$HOME/.local/bin/fnm"
    else
      fnm_bin=$(command -v fnm 2>/dev/null || true)
    fi
    if [[ -n ${fnm_bin:-} ]]; then
      latest=$("$fnm_bin" list-remote --lts 2>/dev/null | tail -n 1 | awk '{print $1}') || true
    fi
  fi
  # Return non-zero (do not die) so callers can degrade gracefully: `inspect`
  # falls back to "resolve-during-apply" and verify_step reports "needed".
  # Callers that genuinely require a version (install_fnm, apply's main) add
  # their own `|| die`.
  node_version_ok "${latest:-}" || return 1
  node_version_compatible "$latest" || return 1
  RESOLVED_NODE_VERSION=$latest
  NODE_SELECTION=current-lts
}

install_starship() { artifact_install starship; }

# uv and uvx; their Zsh completions are cached by zsh/path/uv.zsh (MI-13).
install_uv() { artifact_install uv; }


# The locked packages currently declare simple lower bounds. Refuse a new range
# syntax until its evaluator is implemented instead of silently weakening it.
node_satisfies_engine() {
  local version=${1#v} engine=$2 minimum a b i
  [[ $engine == \>=* ]] || die "Unsupported locked Node engine: $engine"
  minimum=${engine#>=}
  local -a actual_parts minimum_parts
  IFS=. read -r -a actual_parts <<< "$version"
  IFS=. read -r -a minimum_parts <<< "$minimum"
  for i in 0 1 2; do
    a=${actual_parts[$i]:-0}; b=${minimum_parts[$i]:-0}
    [[ $a =~ ^[0-9]+$ && $b =~ ^[0-9]+$ ]] || return 1
    (( 10#$a > 10#$b )) && return 0
    (( 10#$a < 10#$b )) && return 1
  done
  return 0
}

node_version_compatible() {
  node_version_ok "${1:-}" || return 1
  if has_csv_item "$SELECTED_STEPS" yarn; then
    node_satisfies_engine "$1" "$YARN_NODE_ENGINE" || return 1
  fi
  if has_csv_item "$SELECTED_STEPS" pnpm; then
    node_satisfies_engine "$1" "$PNPM_NODE_ENGINE" || return 1
  fi
  return 0
}

select_existing_node() {
  [[ -z $RESOLVED_NODE_VERSION ]] || return 0
  local candidate fnm_bin
  fnm_bin=$(command -v fnm 2>/dev/null || true)
  [[ ! -x $HOME/.local/bin/fnm ]] || fnm_bin=$HOME/.local/bin/fnm
  if [[ -n $fnm_bin ]]; then
    candidate=$("$fnm_bin" default 2>/dev/null || true)
    if node_version_compatible "$candidate" &&
      [[ $("$fnm_bin" exec --using="$candidate" -- node --version 2>/dev/null) == "$candidate" ]]; then
      RESOLVED_NODE_VERSION=$candidate
      NODE_SELECTION=preserved-fnm
      return 0
    fi
  fi
  candidate=$(node --version 2>/dev/null || true)
  if node_version_compatible "$candidate"; then
    RESOLVED_NODE_VERSION=$candidate
    NODE_SELECTION=adopted-existing
    return 0
  fi
  return 1
}

resolve_node_version() {
  [[ -z $RESOLVED_NODE_VERSION ]] || { node_version_compatible "$RESOLVED_NODE_VERSION"; return; }
  select_existing_node || resolve_node_lts
}

fnm_exec() {
  [[ -n $RESOLVED_NODE_VERSION ]] || resolve_node_version || return 1
  "$HOME/.local/bin/fnm" exec --using="$RESOLVED_NODE_VERSION" -- "$@"
}
