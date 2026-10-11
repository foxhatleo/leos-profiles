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

# follow_default_branch <repository> <destination> <label>: a checkout of the
# repository's default branch. A missing one is cloned; an existing one must
# be a clean checkout of the same repository, and is fast-forwarded to
# origin's default branch. A detached checkout (installs before 2026-10 were
# pinned to a commit) is moved onto that branch.
follow_default_branch() {
  local repository=$1 destination=$2 label=$3 origin remote_head branch current
  if [[ ! -d $destination ]]; then
    run mkdir -p "$(dirname -- "$destination")"
    run git clone --quiet "$repository" "$destination"
    return 0
  fi
  [[ -d $destination/.git ]] || die "$label exists but is not a Git checkout: $destination"
  origin=$(git -C "$destination" remote get-url origin 2>/dev/null || true)
  github_origins_equivalent "$origin" "$repository" || die "$label checkout has an unexpected origin: $destination"
  [[ -z $(git -C "$destination" status --porcelain) ]] || die "$label checkout has local changes: $destination"
  if [[ $origin != "$repository" ]]; then
    run git -C "$destination" remote set-url origin "$repository"
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would fast-forward $label to the head of origin's default branch"
    return 0
  fi
  run git -C "$destination" fetch --quiet --prune origin || die "Could not fetch $label from $repository"
  git -C "$destination" remote set-head origin --auto >/dev/null || die "Could not read $label's default branch from $repository"
  remote_head=$(git -C "$destination" symbolic-ref --short refs/remotes/origin/HEAD) ||
    die "Could not read $label's default branch from $repository"
  branch=${remote_head#origin/}
  current=$(git -C "$destination" symbolic-ref --quiet --short HEAD || true)
  if [[ $current == "$branch" ]]; then
    run git -C "$destination" merge --quiet --ff-only "$remote_head" ||
      die "$label has commits that are not on $remote_head: $destination"
  else
    run git -C "$destination" checkout --quiet -B "$branch" "$remote_head"
  fi
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
  follow_default_branch "$PYENV_REPOSITORY" "$HOME/.pyenv" pyenv
  compile_optional_extension "$HOME/.pyenv" pyenv
}

install_rbenv() {
  follow_default_branch "$RBENV_REPOSITORY" "$HOME/.rbenv" rbenv
  follow_default_branch "$RUBY_BUILD_REPOSITORY" "$HOME/.rbenv/plugins/ruby-build" ruby-build
  compile_optional_extension "$HOME/.rbenv" rbenv
}

install_plugins() {
  local directory="$TARGET/zsh/plugins"
  follow_default_branch "$ZSH_AUTOSUGGESTIONS_REPOSITORY" "$directory/zsh-autosuggestions" zsh-autosuggestions
  follow_default_branch "$ZSH_SYNTAX_HIGHLIGHTING_REPOSITORY" "$directory/zsh-syntax-highlighting" zsh-syntax-highlighting
  follow_default_branch "$ZSH_COMPLETIONS_REPOSITORY" "$directory/zsh-completions" zsh-completions
  follow_default_branch "$FZF_TAB_REPOSITORY" "$directory/fzf-tab" fzf-tab
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

# fetch_nerd_font_checksums <destination>: the latest release's SHA-256.txt.
# The release URL can be overridden for tests.
fetch_nerd_font_checksums() {
  download_file "${NERD_FONTS_TEST_RELEASE_URL:-$NERD_FONTS_RELEASE_URL}/SHA-256.txt" "$1"
}

# require_known_nerd_font <SHA-256.txt> <font>: die, before any font download,
# when the release has no archive of that name.
require_known_nerd_font() {
  nerd_font_archive_digest "$1" "$2" >/dev/null ||
    die "Unknown Nerd Font: $2. The latest Nerd Fonts release has no $2.tar.xz; use a name from https://www.nerdfonts.com/font-downloads (for example JetBrainsMono)."
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
    say "Would download $font.tar.xz from the latest Nerd Fonts release, verify it against the release's SHA-256.txt and install it into $(nerd_font_directory)"
    return 0
  fi
  install_nerd_font "$font" "${NERD_FONTS_CHECKSUMS_FILE:-}"
  # On WSL the terminal is a Windows program and reads Windows fonts, so the
  # copy in the Linux guest is not enough (MI-10). Asked once, when the font
  # is installed; the guest copy still verifies, so a reconcile does not ask
  # again.
  if is_wsl; then
    queue_manual_action install-windows-font "$(nerd_font_directory)" "$NERD_FONTS_RELEASE_URL/$font.zip" \
      "WSL: install the $font Nerd Font on Windows as well (download $font.zip, select its .ttf files, Install), then choose \"$(nerd_font_family) Nerd Font\" in your Windows terminal's profile."
  fi
}

ensure_user_npm_prefix() {
  local prefix="$HOME/.local/npm"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would prepare user-local npm prefix: $prefix"
    return 0
  fi
  mkdir -p "$prefix"
}

# Yarn and pnpm: Homebrew formulae on macOS; on Linux the latest npm release,
# installed into ~/.local/npm with fnm's default Node (npm checks the
# registry's integrity hash). Either way they run on fnm's Node.
npm_tool_path() {
  if [[ $OS_FAMILY == macos ]]; then
    printf '%s/bin/%s\n' "$(brew_prefix)" "$1"
  else
    printf '%s\n' "$HOME/.local/npm/bin/$1"
  fi
}

npm_tool_install() {
  local package=$1
  if [[ $OS_FAMILY == macos ]]; then
    remove_legacy_npm_copy "$package"
    brew_tool_install "$package"
  else
    ensure_user_npm_prefix
    if [[ $DRY_RUN -eq 1 ]]; then
      say "Would install the latest $package from npm with fnm's default Node"
      return 0
    fi
    fnm_exec npm install --global --prefix "$HOME/.local/npm" "$package@latest"
  fi
  [[ $DRY_RUN -eq 1 ]] || npm_tool_verify "$package" || die "$package does not run after installation"
}

npm_tool_verify() {
  local package=$1 path
  path=$(npm_tool_path "$package")
  [[ -x $path ]] || return 1
  if [[ $OS_FAMILY == macos ]]; then
    [[ ! -e $HOME/.local/npm/bin/$package ]] || return 1
    load_brew_formulae && brew_formula_installed "$package" || return 1
  fi
  fnm_exec "$path" --version >/dev/null 2>&1
}

install_yarn() { npm_tool_install yarn; }

install_pnpm() { npm_tool_install pnpm; }

machine_arch() {
  case $(uname -m) in
    arm64|aarch64) printf '%s\n' aarch64 ;;
    x86_64|amd64) printf '%s\n' x64 ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac
}

brew_prefix() {
  if [[ -n ${HOMEBREW_PREFIX:-} ]]; then
    printf '%s\n' "$HOMEBREW_PREFIX"
  elif command -v brew >/dev/null 2>&1; then
    brew --prefix
  else
    printf '/opt/homebrew\n'
  fi
}

# brew_tool_install <formula>: install the formula, or on a full upgrade bring
# it up to date (the packages step's `brew upgrade` covers this unless no
# package group is selected).
brew_tool_install() {
  local formula=$1
  ensure_brew
  BREW_FORMULAE=""
  if ! load_brew_formulae || ! brew_formula_installed "$formula"; then
    run brew install "$formula"
  elif [[ $FULL_UPGRADE -eq 1 && -n $(brew outdated --formula --quiet "$formula" 2>/dev/null) ]]; then
    run brew upgrade "$formula"
  fi
  BREW_FORMULAE=""
}

# Installs before 2026-10 put these tools into ~/.local/bin and ~/.local/npm on
# macOS too. Both come before Homebrew on PATH, so a copy left there would
# shadow the formula; remove it once Homebrew's copy is in place.
# legacy_local_copy <artifact>: print each of its executables in ~/.local/bin.
# Only files that report the tool's own --version line count, so an unrelated
# file of the same name is left alone.
legacy_local_copy() {
  local name=$1 executable
  local -a executables=()
  [[ $OS_FAMILY == macos ]] || return 0
  artifact_row "$name"
  [[ $ARTIFACT_ARCHIVE != file ]] || return 0
  IFS=' ' read -r -a executables <<< "$ARTIFACT_EXECUTABLES"
  artifact_version_ok "$name" "$HOME/.local/bin/${executables[0]}" || return 0
  for executable in "${executables[@]}"; do
    [[ ! -e $HOME/.local/bin/$executable ]] || printf '%s\n' "$HOME/.local/bin/$executable"
  done
}

remove_legacy_local_copy() {
  local path
  while IFS= read -r path; do
    run rm -f -- "$path"
  done < <(legacy_local_copy "$1")
}

# remove_legacy_npm_copy <yarn|pnpm>: the package and the commands npm linked
# for it in ~/.local/npm.
remove_legacy_npm_copy() {
  local package=$1 command prefix="$HOME/.local/npm"
  [[ -e $prefix/bin/$package || -d $prefix/lib/node_modules/$package ]] || return 0
  run rm -rf -- "$prefix/lib/node_modules/$package"
  for command in "$package" yarnpkg pnpx; do
    case $package:$command in
      yarn:pnpx|pnpm:yarnpkg) continue ;;
    esac
    [[ ! -e $prefix/bin/$command && ! -L $prefix/bin/$command ]] || run rm -f -- "$prefix/bin/$command"
  done
}

# github_latest_asset <owner/repo> <asset>: print "<tag><TAB><url><TAB><sha256>"
# for the asset in the project's latest release. The digest is the one GitHub
# computes for every release asset. GITHUB_TOKEN, when set, lifts the API's
# anonymous limit of 60 requests an hour.
github_latest_asset() {
  local repository=$1 asset=$2 api json record tag url digest
  local -a curl_args=(--fail --location --proto '=https' --tlsv1.2 --silent --show-error
    --connect-timeout 15 --max-time 60 --retry 3 -H 'Accept: application/vnd.github+json')
  api="https://api.github.com/repos/$repository/releases/latest"
  if [[ -n ${GITHUB_TOKEN:-} ]] && json=$(curl "${curl_args[@]}" -H "Authorization: Bearer $GITHUB_TOKEN" "$api" 2>/dev/null); then
    :
  else
    json=$(curl "${curl_args[@]}" "$api") || die "Could not read the latest $repository release from GitHub"
  fi
  record=$(github_release_asset_record "$asset" <<< "$json") ||
    die "The latest $repository release has no $asset"
  IFS=$'\t' read -r tag url digest <<< "$record"
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "GitHub publishes no SHA-256 digest for $asset in $repository $tag"
  [[ $url == https://github.com/* ]] || die "Unexpected download URL for $asset in $repository: $url"
  printf '%s\t%s\t%s\n' "$tag" "$url" "${digest#sha256:}"
}

# github_release_asset_record <asset> < release.json: "<tag><TAB><url><TAB><digest>".
# The release JSON is split into "key": value tokens; an asset's name comes
# before its digest and download URL, and the uploader object between them
# has none of those keys.
github_release_asset_record() {
  awk -v want="$1" '
    function value(text) {
      sub(/^"[^"]*"[ \t]*:[ \t]*"?/, "", text)
      sub(/"$/, "", text)
      return text
    }
    BEGIN { RS = "[],{}[]" }
    {
      gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "")
      if ($0 ~ /^"tag_name"[ \t]*:/ && tag == "") tag = value($0)
      else if ($0 ~ /^"name"[ \t]*:/) current = value($0)
      else if (current == want && $0 ~ /^"digest"[ \t]*:/) digest = value($0)
      else if (current == want && $0 ~ /^"browser_download_url"[ \t]*:/) url = value($0)
    }
    END {
      if (tag == "" || url == "") exit 1
      printf "%s\t%s\t%s\n", tag, url, digest
    }
  '
}

# release_version <tag>: the version in a release tag (bun-v1.2.3 -> 1.2.3).
release_version() {
  local tag=$1
  printf '%s\n' "${tag#"${tag%%[0-9]*}"}"
}

# install_archive_binary <tool> <zip|tar.gz> <url> <sha256> <destination> [extra...]:
# download the verified archive and install its <tool> executable at
# <destination>, and each extra executable beside it.
install_archive_binary() {
  local tool=$1 extension=$2 url=$3 sha=$4 destination=$5 temp archive binary extra
  shift 5
  temp=$(mktemp -d)
  track_temp "$temp"
  archive="$temp/$tool.$extension"
  download_verified "$url" "$sha" "$archive"
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

# artifact_version_ok <name> <executable> [version]: the executable reports
# the registry's version line on the first line of --version (optionally
# followed by build details after a space): for the given version, or any.
artifact_version_ok() {
  local name=$1 executable=$2 version=${3:-} expected first
  artifact_row "$name"
  [[ -x $executable ]] || return 1
  first=$("$executable" --version 2>/dev/null | sed -n '1p') || return 1
  if [[ -n $version ]]; then
    # shellcheck disable=SC2059  # the registry column is the format
    printf -v expected "$ARTIFACT_VERSION_LINE" "$version"
    [[ $first == "$expected" || $first == "$expected "* ]]
  else
    expected=${ARTIFACT_VERSION_LINE//%s/[0-9]*}
    # shellcheck disable=SC2053  # a glob on purpose: any version
    [[ $first == $expected ]]
  fi
}

# artifact_path <name>: where its main executable is installed.
artifact_path() {
  local -a executables=()
  artifact_row "$1"
  IFS=' ' read -r -a executables <<< "$ARTIFACT_EXECUTABLES"
  if [[ $(artifact_source "$1") == formula ]]; then
    printf '%s/bin/%s\n' "$(brew_prefix)" "${executables[0]}"
  else
    printf '%s\n' "$HOME/.local/bin/${executables[0]}"
  fi
}

# artifact_install <name> [directory]: install a registry artifact from its
# source (artifact_source). Release and pinned artifacts go into ~/.local/bin,
# or the directory.
artifact_install() {
  local name=$1 directory=${2:-$HOME/.local/bin} url sha main record repository asset tag version present=1 executable
  local -a executables=()
  artifact_row "$name"
  IFS=' ' read -r -a executables <<< "$ARTIFACT_EXECUTABLES"
  main=${executables[0]}
  case $(artifact_source "$name") in
    pinned)
      IFS=$'\t' read -r url sha <<< "$(artifact_pinned_asset "$name")"
      download_verified "$url" "$sha" "$directory/$main"
      [[ $DRY_RUN -eq 1 ]] || chmod 700 "$directory/$main" ;;
    formula)
      brew_tool_install "$ARTIFACT_FORMULA"
      remove_legacy_local_copy "$name" ;;
    release)
      record=$(artifact_release_asset "$name") || die "$name publishes no Linux build for $(uname -m)"
      IFS=$'\t' read -r repository asset <<< "$record"
      if [[ $DRY_RUN -eq 1 ]]; then
        say "Would install the latest $name release ($asset from github.com/$repository), checked against GitHub's SHA-256 digest"
        return 0
      fi
      record=$(github_latest_asset "$repository" "$asset") || exit 1
      IFS=$'\t' read -r tag url sha <<< "$record"
      version=$(release_version "$tag")
      for executable in "${executables[@]}"; do
        [[ -x $directory/$executable ]] || present=0
      done
      if (( present )) && artifact_version_ok "$name" "$directory/$main" "$version"; then
        say "$name $version is the latest release and already installed"
        return 0
      fi
      install_archive_binary "$main" "$ARTIFACT_ARCHIVE" "$url" "$sha" "$directory/$main" ${executables[1]+"${executables[@]:1}"}
      artifact_version_ok "$name" "$directory/$main" "$version" || die "$name does not report version $version after installation" ;;
  esac
}

# artifact_verify <name>: the artifact is installed from its source: the
# pinned digest for a pinned file; otherwise every executable present and the
# main one reporting a version, and on macOS the formula installed with no
# older ~/.local/bin copy in front of it.
artifact_verify() {
  local name=$1 directory="$HOME/.local/bin" executable url sha source
  local -a executables=()
  artifact_row "$name"
  IFS=' ' read -r -a executables <<< "$ARTIFACT_EXECUTABLES"
  source=$(artifact_source "$name")
  case $source in
    pinned)
      [[ -x $directory/${executables[0]} ]] || return 1
      IFS=$'\t' read -r url sha <<< "$(artifact_pinned_asset "$name")"
      [[ $(sha256 "$directory/${executables[0]}") == "$sha" ]] ;;
    formula)
      load_brew_formulae && brew_formula_installed "$ARTIFACT_FORMULA" || return 1
      [[ -z $(legacy_local_copy "$name") ]] || return 1
      directory="$(brew_prefix)/bin"
      for executable in "${executables[@]}"; do
        [[ -x $directory/$executable ]] || return 1
      done
      artifact_version_ok "$name" "$directory/${executables[0]}" ;;
    release)
      for executable in "${executables[@]}"; do
        [[ -x $directory/$executable ]] || return 1
      done
      artifact_version_ok "$name" "$directory/${executables[0]}" ;;
  esac
}

install_bun() { artifact_install bun; }

fnm_path() { artifact_path fnm; }

install_fnm() {
  local fnm
  artifact_install fnm
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would install the current Node LTS with fnm and make it the default"
    return 0
  fi
  resolve_node_version || die "Could not resolve the current Node LTS"
  say "Selected Node $RESOLVED_NODE_VERSION (current LTS)"
  fnm=$(fnm_path)
  eval "$("$fnm" env --shell bash)"
  run "$fnm" install "$RESOLVED_NODE_VERSION"
  run "$fnm" default "$RESOLVED_NODE_VERSION"
  run "$fnm" use "$RESOLVED_NODE_VERSION"
}

node_version_ok() { [[ ${1:-} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# The Node release index, from FNM_NODE_DIST_MIRROR when set (fnm honours the
# same variable for its downloads), so a mirror serves both (ONB-10). It must
# be an https URL.
node_dist_index_url() {
  local base=${FNM_NODE_DIST_MIRROR:-https://nodejs.org/dist}
  printf '%s/index.tab\n' "${base%/}"
}

# resolve_node_version: RESOLVED_NODE_VERSION becomes the current Node LTS.
# Returns non-zero (does not die) so callers can degrade gracefully: `inspect`
# falls back to "resolve-during-apply". install_fnm adds its own `|| die`.
resolve_node_version() {
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
    fnm_bin=$(fnm_path)
    [[ -x $fnm_bin ]] || fnm_bin=$(command -v fnm 2>/dev/null || true)
    if [[ -n ${fnm_bin:-} ]]; then
      latest=$("$fnm_bin" list-remote --lts 2>/dev/null | tail -n 1 | awk '{print $1}') || true
    fi
  fi
  node_version_ok "${latest:-}" || return 1
  RESOLVED_NODE_VERSION=$latest
  NODE_SELECTION="current-lts"
}

# fnm_default_node: the version fnm's default alias points at, if it runs.
fnm_default_node() {
  local fnm version
  fnm=$(fnm_path)
  [[ -x $fnm ]] || return 1
  version=$("$fnm" default 2>/dev/null) || return 1
  node_version_ok "$version" || return 1
  [[ $("$fnm" exec --using=default -- node --version 2>/dev/null) == "$version" ]] || return 1
  printf '%s\n' "$version"
}

# node_default_kept: print the installed default when this run leaves it
# alone: no full upgrade, and the fnm step is recorded and verifies, so it is
# skipped. Otherwise the run installs the current LTS.
node_default_kept() {
  [[ $FULL_UPGRADE -eq 0 ]] && state_done fnm && verify_step fnm || return 1
  fnm_default_node
}

install_starship() { artifact_install starship; }

# uv and uvx; their Zsh completions are cached by zsh/path/uv.zsh (MI-13).
install_uv() { artifact_install uv; }

fnm_exec() {
  "$(fnm_path)" exec --using=default -- "$@"
}
