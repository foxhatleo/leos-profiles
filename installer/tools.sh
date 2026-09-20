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

install_local_bins() {
  local destination="$HOME/.local/bin/rpatool"
  download_verified "$RPATOOL_URL" "$RPATOOL_SHA256" "$destination"
  [[ $DRY_RUN -eq 1 ]] || chmod 700 "$destination"
}

install_pyenv() {
  clone_pinned "$PYENV_REPOSITORY" "$PYENV_COMMIT" "$HOME/.pyenv" pyenv
  if [[ $DRY_RUN -eq 0 ]]; then
    (cd "$HOME/.pyenv" && src/configure && make -C src)
  fi
}

install_rbenv() {
  clone_pinned "$RBENV_REPOSITORY" "$RBENV_COMMIT" "$HOME/.rbenv" rbenv
  clone_pinned "$RUBY_BUILD_REPOSITORY" "$RUBY_BUILD_COMMIT" "$HOME/.rbenv/plugins/ruby-build" ruby-build
  if [[ $DRY_RUN -eq 0 && -x $HOME/.rbenv/src/configure ]]; then
    (cd "$HOME/.rbenv" && src/configure && make -C src)
  fi
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

# Blobless, shallow, cone-sparse checkout of a pinned commit limited to the
# given paths. For a huge monorepo (nerd-fonts) this fetches only the requested
# font's blobs instead of the whole multi-GB tree/history. Returns non-zero on
# any failure so callers can fall back to a full checkout; content trust is
# unchanged (the pinned commit is still asserted).
sparse_checkout_pinned() {
  local repository=$1 commit=$2 destination=$3 label=$4
  shift 4
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would sparse-checkout $label ($*) at the pinned commit"
    return 0
  fi
  mkdir -p "$destination" &&
    git -C "$destination" init -q &&
    git -C "$destination" remote add origin "$repository" &&
    git -C "$destination" config extensions.partialClone origin &&
    git -C "$destination" sparse-checkout init --cone &&
    git -C "$destination" sparse-checkout set "$@" &&
    git -C "$destination" fetch --depth 1 --filter=blob:none origin "$commit" &&
    git -C "$destination" checkout --detach FETCH_HEAD || return 1
  [[ $(git -C "$destination" rev-parse HEAD) == "$commit" ]] || return 1
}

install_fonts() {
  if ! font_should_install; then
    say "Skipping Nerd Fonts ($INSTALL_FONTS policy)"
    return 0
  fi
  local font=${FONT_NAME:-JetBrainsMono}
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would download pinned Nerd Fonts and install $font"
    return 0
  fi
  local temp checkout
  temp=$(mktemp -d)
  track_temp "$temp"
  checkout="$temp/nerd-fonts"
  # Fast path: fetch only this font's files. Fall back to a full pinned checkout
  # (the original behavior) if the sparse layout doesn't satisfy the upstream
  # installer, so no supported font can regress.
  if sparse_checkout_pinned "$NERD_FONTS_REPOSITORY" "$NERD_FONTS_COMMIT" "$checkout" nerd-fonts \
       install.sh bin "patched-fonts/$font" && "$checkout/install.sh" "$font"; then
    :
  else
    say "Sparse Nerd Fonts install did not complete; retrying with a full pinned checkout"
    rm -rf "$checkout"
    clone_pinned "$NERD_FONTS_REPOSITORY" "$NERD_FONTS_COMMIT" "$checkout" nerd-fonts
    run "$checkout/install.sh" "$font"
  fi
  rm -rf "$temp"
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

platform_asset() {
  local tool=$1 arch
  arch=$(machine_arch)
  case "$tool:$OS_FAMILY:$arch" in
    bun:macos:aarch64) printf '%s\t%s\n' "$BUN_DARWIN_AARCH64_URL" "$BUN_DARWIN_AARCH64_SHA256" ;;
    bun:macos:x64) printf '%s\t%s\n' "$BUN_DARWIN_X64_URL" "$BUN_DARWIN_X64_SHA256" ;;
    bun:apt:aarch64|bun:fedora:aarch64|bun:arch:aarch64) printf '%s\t%s\n' "$BUN_LINUX_AARCH64_URL" "$BUN_LINUX_AARCH64_SHA256" ;;
    bun:apt:x64|bun:fedora:x64|bun:arch:x64) printf '%s\t%s\n' "$BUN_LINUX_X64_URL" "$BUN_LINUX_X64_SHA256" ;;
    fnm:macos:aarch64|fnm:macos:x64) printf '%s\t%s\n' "$FNM_MACOS_URL" "$FNM_MACOS_SHA256" ;;
    fnm:apt:aarch64|fnm:fedora:aarch64|fnm:arch:aarch64) printf '%s\t%s\n' "$FNM_LINUX_AARCH64_URL" "$FNM_LINUX_AARCH64_SHA256" ;;
    fnm:apt:x64|fnm:fedora:x64|fnm:arch:x64) printf '%s\t%s\n' "$FNM_LINUX_X64_URL" "$FNM_LINUX_X64_SHA256" ;;
    starship:macos:aarch64) printf '%s\t%s\n' "$STARSHIP_DARWIN_AARCH64_URL" "$STARSHIP_DARWIN_AARCH64_SHA256" ;;
    starship:macos:x64) printf '%s\t%s\n' "$STARSHIP_DARWIN_X64_URL" "$STARSHIP_DARWIN_X64_SHA256" ;;
    starship:apt:aarch64|starship:fedora:aarch64|starship:arch:aarch64) printf '%s\t%s\n' "$STARSHIP_LINUX_AARCH64_URL" "$STARSHIP_LINUX_AARCH64_SHA256" ;;
    starship:apt:x64|starship:fedora:x64|starship:arch:x64) printf '%s\t%s\n' "$STARSHIP_LINUX_X64_URL" "$STARSHIP_LINUX_X64_SHA256" ;;
    *) die "No locked $tool artifact for $OS_FAMILY/$arch" ;;
  esac
}

install_locked_archive_binary() {
  local tool=$1 extension=$2 destination=$3 url sha temp archive binary asset
  asset=$(platform_asset "$tool")
  local IFS=$'\t'
  read -r url sha <<< "$asset"
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
  rm -rf "$temp"
}

install_bun() {
  install_locked_archive_binary bun zip "$HOME/.local/bin/bun"
  [[ $DRY_RUN -eq 1 ]] || "$HOME/.local/bin/bun" --version | grep -qx "$BUN_VERSION" || die "Bun version verification failed"
}

install_fnm() {
  install_locked_archive_binary fnm zip "$HOME/.local/bin/fnm"
  [[ $DRY_RUN -eq 1 ]] || "$HOME/.local/bin/fnm" --version | grep -qx "fnm $FNM_VERSION" || die "fnm version verification failed"
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
      https://nodejs.org/dist/index.tab 2>/dev/null | awk -F '\t' 'NR > 1 && $10 != "-" { print $1; exit }') || true
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

install_starship() {
  install_locked_archive_binary starship tar.gz "$HOME/.local/bin/starship"
  [[ $DRY_RUN -eq 1 ]] || "$HOME/.local/bin/starship" --version | grep -q "starship $STARSHIP_VERSION" || die "Starship version verification failed"
}


# The locked packages currently declare simple lower bounds. Refuse a new range
# syntax until its evaluator is implemented instead of silently weakening it.
node_satisfies_engine() {
  local version=${1#v} engine=$2 minimum a b i
  [[ $engine == \>=* ]] || die "Unsupported locked Node engine: $engine"
  minimum=${engine#>=}
  local -a actual_parts minimum_parts
  local IFS=.
  read -r -a actual_parts <<< "$version"
  read -r -a minimum_parts <<< "$minimum"
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
