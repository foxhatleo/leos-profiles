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

# ---------------------------------------------------------------------------
# Minimum release age. RELEASE_CUTOFF_EPOCH and RELEASE_CUTOFF_ISO (UTC,
# 2026-11-05T12:00:00Z, the shape of GitHub's published_at, so the two compare
# as strings) are MIN_RELEASE_AGE days before now, computed once per run.
# They are globals: call release_age_cutoff in the current shell.
RELEASE_CUTOFF_EPOCH=""
RELEASE_CUTOFF_ISO=""

# A function so tests can fix "now".
current_epoch() { date +%s; }

# epoch_to_iso <seconds>: with GNU date (-d @N), or else BSD date (-r N).
epoch_to_iso() {
  if date --version >/dev/null 2>&1; then
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
  fi
}

release_age_cutoff() {
  [[ -z $RELEASE_CUTOFF_EPOCH ]] || return 0
  local now iso
  now=$(current_epoch)
  [[ $now =~ ^[0-9]+$ ]] || die "Could not read the current time"
  iso=$(epoch_to_iso "$(( now - MIN_RELEASE_AGE * 86400 ))") || die "Could not compute the release-age cutoff"
  RELEASE_CUTOFF_EPOCH=$(( now - MIN_RELEASE_AGE * 86400 ))
  RELEASE_CUTOFF_ISO=$iso
}

# min_release_age_ok <value>: a whole number of days, 0 to 365.
min_release_age_ok() {
  local pattern='^(0|[1-9][0-9]?[0-9]?)$'
  [[ $1 =~ $pattern ]] && (( $1 <= 365 ))
}

# ---------------------------------------------------------------------------
# Git checkouts. Each source in sources.sh has <PREFIX>_REPOSITORY and a
# follow mode, <PREFIX>_FOLLOW (tag, commit or tag-now). The checkout ends
# detached at the release that mode picks; it may move backwards (the newest
# old-enough release can be older than what an earlier run checked out). Local
# work is never thrown away: uncommitted changes, or commits that were never on
# origin, stop the step.

# A stable release tag: v1.2.3, 0.36.0, v20261023. Not 1.0-rc1, 0.8.0-alpha1.
readonly STABLE_TAG_PATTERN='^v?[0-9]+([.][0-9]+)*$'

# follow_mode_description <mode>: what the mode checks out, for messages.
follow_mode_description() {
  case $1 in
    tag) printf 'the newest stable tag at least %s days old\n' "$MIN_RELEASE_AGE" ;;
    commit) printf 'the newest default-branch commit at least %s days old\n' "$MIN_RELEASE_AGE" ;;
    tag-now) printf 'the newest stable tag\n' ;;
    *) die "Unknown follow mode: $1" ;;
  esac
}

# release_checkout_target <checkout> <mode>: sets FOLLOW_TARGET (a commit) and
# FOLLOW_TARGET_NAME (the tag, or the commit's short hash) from the refs the
# checkout already has, or returns 1 when there is none. It reads only: call it
# after a fetch to pick from what origin has now. Call it in the current shell.
FOLLOW_TARGET=""
FOLLOW_TARGET_NAME=""
release_checkout_target() {
  local directory=$1 mode=$2 tag any=0
  FOLLOW_TARGET=""
  FOLLOW_TARGET_NAME=""
  release_age_cutoff
  case $mode in
    commit)
      FOLLOW_TARGET=$(git -C "$directory" rev-list -1 --before="@$RELEASE_CUTOFF_EPOCH" refs/remotes/origin/HEAD 2>/dev/null) ||
        return 1
      [[ -n $FOLLOW_TARGET ]] || return 1
      FOLLOW_TARGET_NAME=$(git -C "$directory" rev-parse --short "$FOLLOW_TARGET") || return 1 ;;
    tag|tag-now)
      [[ $mode == tag ]] || any=1
      # Newest first by the tag's own date (the tagger's, or for a lightweight
      # tag its commit's).
      tag=$(git -C "$directory" for-each-ref --sort=-creatordate --format='%(refname)%09%(creatordate:unix)' refs/tags |
        awk -F '\t' -v pattern="$STABLE_TAG_PATTERN" -v cutoff="$RELEASE_CUTOFF_EPOCH" -v any="$any" '
          {
            tag = $1
            sub(/^refs\/tags\//, "", tag)
            if (tag ~ pattern && (any || $2 + 0 <= cutoff + 0)) { print tag; exit }
          }')
      [[ -n $tag ]] || return 1
      FOLLOW_TARGET=$(git -C "$directory" rev-parse --verify --quiet "refs/tags/$tag^{commit}") || return 1
      FOLLOW_TARGET_NAME=$tag ;;
    *) die "Unknown follow mode: $mode" ;;
  esac
}

# follow_release_checkout <PREFIX> <destination> <label>: a checkout of
# <PREFIX>_REPOSITORY, detached at what <PREFIX>_FOLLOW picks. A missing one is
# cloned; an existing one must be a clean checkout of the same repository.
follow_release_checkout() {
  local prefix=$1 destination=$2 label=$3 repository_var mode_var repository mode describe origin unpublished head
  repository_var=${prefix}_REPOSITORY
  mode_var=${prefix}_FOLLOW
  repository=${!repository_var}
  mode=${!mode_var}
  describe=$(follow_mode_description "$mode")
  if [[ ! -d $destination ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      say "Would clone $label from $repository and check out $describe"
      return 0
    fi
    run mkdir -p "$(dirname -- "$destination")"
    run git clone --quiet "$repository" "$destination"
  else
    [[ -d $destination/.git ]] || die "$label exists but is not a Git checkout: $destination"
    origin=$(git -C "$destination" remote get-url origin 2>/dev/null || true)
    github_origins_equivalent "$origin" "$repository" || die "$label checkout has an unexpected origin: $destination"
    [[ -z $(git -C "$destination" status --porcelain) ]] || die "$label checkout has local changes: $destination"
    # Before fetching, while the remote-tracking refs and tags still hold what
    # origin had at the last fetch: a checked-out commit that none of them
    # contains was made here. (Commits upstream later force-pushed away were
    # origin's at that point, so they do not count.)
    unpublished=$(git -C "$destination" rev-list HEAD --not --remotes=origin --tags) ||
      die "Could not compare $label with $repository: $destination"
    [[ -z $unpublished ]] ||
      die "$label has commits that are not on $repository: $destination (for example $(sed -n '1p' <<< "$unpublished")). Nothing was changed; keep them on a branch of your own, check out a commit from origin and rerun."
    if [[ $origin != "$repository" ]]; then
      run git -C "$destination" remote set-url origin "$repository"
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
      say "Would fetch $label and check out $describe"
      return 0
    fi
  fi
  # --prune-tags with --force: the checkout's tags mirror origin's, so a
  # release upstream deleted or moved is not picked from a stale local tag.
  run git -C "$destination" fetch --quiet --prune --prune-tags --force --tags origin ||
    die "Could not fetch $label from $repository"
  git -C "$destination" remote set-head origin --auto >/dev/null ||
    die "Could not read $label's default branch from $repository"
  release_checkout_target "$destination" "$mode" ||
    die "$label: $repository has nothing to check out as $describe. Rerun with a smaller --min-release-age."
  head=$(git -C "$destination" rev-parse --verify --quiet HEAD || true)
  if [[ $head == "$FOLLOW_TARGET" ]] && ! git -C "$destination" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
    say "$label is at $FOLLOW_TARGET_NAME ($describe)"
    return 0
  fi
  if [[ -n $head && -n $(git -C "$destination" rev-list -1 "$head" --not --remotes=origin --tags) ]]; then
    say "$label's upstream rewrote its history (a force-push): $destination was at a commit origin no longer has, with no commits of your own"
  fi
  run git -C "$destination" checkout --quiet --detach "$FOLLOW_TARGET"
  say "$label is now at $FOLLOW_TARGET_NAME ($describe)"
}

install_local_bins() { artifact_install rpatool; }

# rbenv ships an optional native extension that speeds up its bash code. It
# works without it, so a failed compile only warns (BP-10).
compile_optional_extension() {
  local root=$1 label=$2
  [[ $DRY_RUN -eq 0 && -x $root/src/configure ]] || return 0
  if ! (cd "$root" && src/configure && make -C src); then
    warn "$label's optional native extension did not compile; $label works without it, a little slower."
  fi
}

# rbenv and ruby-build at their releases, then the newest stable Ruby
# (install_ruby). pyenv is no longer installed (schema 4): uv's CPython
# replaces it, and an existing ~/.pyenv is left alone.
install_rbenv() {
  follow_release_checkout RBENV "$HOME/.rbenv" rbenv
  follow_release_checkout RUBY_BUILD "$HOME/.rbenv/plugins/ruby-build" ruby-build
  compile_optional_extension "$HOME/.rbenv" rbenv
  install_ruby
}

install_plugins() {
  local directory="$TARGET/zsh/plugins"
  follow_release_checkout ZSH_AUTOSUGGESTIONS "$directory/zsh-autosuggestions" zsh-autosuggestions
  follow_release_checkout ZSH_SYNTAX_HIGHLIGHTING "$directory/zsh-syntax-highlighting" zsh-syntax-highlighting
  follow_release_checkout ZSH_COMPLETIONS "$directory/zsh-completions" zsh-completions
  follow_release_checkout FZF_TAB "$directory/fzf-tab" fzf-tab
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

# nerd_fonts_release: NERD_FONTS_RELEASE_BASE becomes the download URL
# (.../releases/download/<tag>) of the newest Nerd Fonts release at least
# MIN_RELEASE_AGE days old, once per run (preflight resolves it first); the
# checksum list and the archive both come from it. It sets globals, so call it
# in the current shell, never inside $(...). NERD_FONTS_TEST_RELEASE_URL
# replaces the base in tests.
NERD_FONTS_RELEASE_BASE=""
NERD_FONTS_TAG=""
NERD_FONTS_PUBLISHED=""
nerd_fonts_release() {
  [[ -z $NERD_FONTS_RELEASE_BASE ]] || return 0
  if [[ -n ${NERD_FONTS_TEST_RELEASE_URL:-} ]]; then
    NERD_FONTS_RELEASE_BASE=$NERD_FONTS_TEST_RELEASE_URL
    return 0
  fi
  local status=0
  github_release_tag_pick "$NERD_FONTS_REPOSITORY" || status=$?
  case $status in
    0) ;;
    "$GITHUB_LOOKUP_TOO_NEW") die "No Nerd Fonts release among the 30 newest is at least $MIN_RELEASE_AGE days old; rerun with a smaller --min-release-age" ;;
    "$GITHUB_LOOKUP_REFUSED") die "Could not read the Nerd Fonts releases: GitHub refused the request (HTTP 403/429), most likely the anonymous API rate limit. Set GITHUB_TOKEN, or log in with gh, and rerun." ;;
    *) die "Could not read the Nerd Fonts releases from GitHub; check the network and rerun" ;;
  esac
  NERD_FONTS_TAG=$RELEASE_TAG
  NERD_FONTS_PUBLISHED=$RELEASE_PUBLISHED
  NERD_FONTS_RELEASE_BASE="$NERD_FONTS_DOWNLOAD_URL/$RELEASE_TAG"
}

# fetch_nerd_font_checksums <destination>: the resolved release's SHA-256.txt.
fetch_nerd_font_checksums() {
  nerd_fonts_release
  download_file "$NERD_FONTS_RELEASE_BASE/SHA-256.txt" "$1"
}

# require_known_nerd_font <SHA-256.txt> <font>: die, before any font download,
# when the release has no archive of that name.
require_known_nerd_font() {
  nerd_font_archive_digest "$1" "$2" >/dev/null ||
    die "Unknown Nerd Font: $2. The Nerd Fonts release ${NERD_FONTS_TAG:-picked} has no $2.tar.xz; use a name from https://www.nerdfonts.com/font-downloads (for example JetBrainsMono)."
}

# install_nerd_font <font> [verified SHA-256.txt]: download the font's release
# archive, verify it against the checksum list and install its font files.
install_nerd_font() {
  local font=$1 checksums=${2:-} release
  local temp digest directory file found=0
  nerd_fonts_release
  release=$NERD_FONTS_RELEASE_BASE
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
    say "Would download $font.tar.xz from the newest Nerd Fonts release at least $MIN_RELEASE_AGE days old, verify it against the release's SHA-256.txt and install it into $(nerd_font_directory)"
    return 0
  fi
  install_nerd_font "$font" "${NERD_FONTS_CHECKSUMS_FILE:-}"
  # On WSL the terminal is a Windows program and reads Windows fonts, so the
  # copy in the Linux guest is not enough (MI-10). Asked once, when the font
  # is installed; the guest copy still verifies, so a reconcile does not ask
  # again.
  if is_wsl; then
    queue_manual_action install-windows-font "$(nerd_font_directory)" "$NERD_FONTS_RELEASE_BASE/$font.zip" \
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

# ---------------------------------------------------------------------------
# Corepack (schema 4; it replaces the yarn and pnpm components). On every OS
# the latest Corepack from npm, installed with fnm's default Node into
# ~/.local/npm (Homebrew's corepack formula would pull in Homebrew's node).
# Its pnpm and Yarn shims sit in ~/.local/npm/bin, ahead of any other copy on
# PATH, and run on fnm's Node; outside a project with a packageManager field
# they use the versions installed here: pnpm's latest and Yarn's stable
# (modern) release. Yarn Classic (1.x) is no longer installed; a project that
# pins it still gets it, through Corepack.
COREPACK_PREFIX_NAME=.local/npm
COREPACK_TOOLS="pnpm yarn"
COREPACK_DEFAULTS="pnpm@latest yarn@stable"

corepack_prefix() { printf '%s\n' "$HOME/$COREPACK_PREFIX_NAME"; }

# legacy_npm_copy_present <yarn|pnpm>: the yarn or pnpm npm package an older
# install put into ~/.local/npm (not Corepack's shim of the same name).
legacy_npm_copy_present() {
  local prefix link
  prefix=$(corepack_prefix)
  link="$prefix/bin/$1"
  [[ ! -d $prefix/lib/node_modules/$1 ]] || return 0
  [[ -e $link || -L $link ]] || return 1
  [[ $(readlink "$link" 2>/dev/null || true) != *corepack* ]]
}

# retired_formula_installed <yarn|pnpm>: macOS: the profile's retired yarn or
# pnpm step installed (or adopted) this Homebrew formula, and it is still
# installed. The state file keeps those steps' rows until this step has dealt
# with them (migrate_local_state).
retired_formula_installed() {
  [[ $OS_FAMILY == macos ]] || return 1
  [[ -f $STATE_FILE ]] && awk -F '\t' -v step="$1" '$1 == step { found = 1 } END { exit !found }' "$STATE_FILE" || return 1
  load_brew_formulae && brew_formula_installed "$1"
}

# remove_retired_npm_tools: what the retired yarn and pnpm steps left in the
# way: their npm packages in ~/.local/npm (npm would refuse to link Corepack's
# shims over them), and on macOS the Homebrew formulae the profile installed.
# Then their state rows go.
remove_retired_npm_tools() {
  local tool status
  for tool in $COREPACK_TOOLS; do
    if legacy_npm_copy_present "$tool"; then remove_legacy_npm_copy "$tool"; fi
    if retired_formula_installed "$tool"; then
      status=0
      run brew uninstall --formula "$tool" || status=$?
      BREW_FORMULAE=""
      (( status == 0 )) ||
        warn "Could not uninstall Homebrew's $tool (status $status); Corepack's $tool in ~/.local/npm/bin comes first on PATH anyway. Remove it with: brew uninstall $tool"
    fi
  done
  drop_state_rows yarn pnpm
}

install_corepack() {
  local prefix tool
  prefix=$(corepack_prefix)
  if [[ $DRY_RUN -eq 1 ]]; then
    remove_retired_npm_tools
    say "Would install the latest Corepack from npm with fnm's default Node into $prefix, enable its pnpm and Yarn shims in $prefix/bin and install $COREPACK_DEFAULTS"
    return 0
  fi
  remove_retired_npm_tools
  ensure_user_npm_prefix
  fnm_exec npm install --global --prefix "$prefix" corepack@latest
  fnm_exec "$prefix/bin/corepack" enable --install-directory "$prefix/bin"
  # shellcheck disable=SC2086  # the defaults are separate words
  fnm_exec env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 "$prefix/bin/corepack" install --global $COREPACK_DEFAULTS
  # Run each once while the network is allowed: current pnpm releases fetch
  # their native binary on first use, and verify_corepack runs offline.
  for tool in $COREPACK_TOOLS; do
    corepack_tool_version "$tool" >/dev/null || die "Corepack's $tool does not run after installation"
  done
  verify_corepack || die "Corepack's pnpm or Yarn does not run after installation"
}

# corepack_tool_version <pnpm|yarn> [VAR=value...]: the tool's --version
# through its Corepack shim on fnm's default Node, run from / so that no
# project's packageManager field picks another version.
corepack_tool_version() {
  local tool=$1 prefix
  shift
  prefix=$(corepack_prefix)
  (cd / && fnm_exec env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 ${1+"$@"} "$prefix/bin/$tool" --version) 2>/dev/null
}

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
# for it in ~/.local/npm (the retired yarn and pnpm components; macOS installs
# before 2026-10 used it too).
remove_legacy_npm_copy() {
  local package=$1 command prefix="$HOME/.local/npm"
  # The name becomes part of an `rm -rf` path: never a traversal or another package.
  [[ $package == yarn || $package == pnpm ]] || die "No legacy npm copy to remove for: $package"
  [[ -e $prefix/bin/$package || -L $prefix/bin/$package || -d $prefix/lib/node_modules/$package ]] || return 0
  run rm -rf -- "$prefix/lib/node_modules/$package"
  for command in "$package" yarnpkg pnpx; do
    case $package:$command in
      yarn:pnpx|pnpm:yarnpkg) continue ;;
    esac
    [[ ! -e $prefix/bin/$command && ! -L $prefix/bin/$command ]] || run rm -f -- "$prefix/bin/$command"
  done
}

# ---------------------------------------------------------------------------
# GitHub releases. A lookup that cannot read GitHub returns a status instead
# of dying, so artifact_install can keep a copy that is installed and still
# verifies: GITHUB_LOOKUP_UNREACHABLE (network, 5xx), GITHUB_LOOKUP_REFUSED
# (HTTP 403/429, most likely the anonymous limit of 60 requests an hour),
# GITHUB_LOOKUP_NOT_FOUND (404) or GITHUB_LOOKUP_TOO_NEW (none of the 30
# newest releases is old enough). A release that does not publish the asset
# properly still dies.
GITHUB_LOOKUP_UNREACHABLE=4
GITHUB_LOOKUP_REFUSED=5
GITHUB_LOOKUP_NOT_FOUND=6
GITHUB_LOOKUP_TOO_NEW=7

# github_api_token: GITHUB_API_TOKEN becomes GITHUB_TOKEN, or else gh's token
# when gh is logged in, so lookups stay under the anonymous rate limit. Once
# per run, in the current shell (it sets globals).
GITHUB_API_TOKEN=""
GITHUB_API_TOKEN_RESOLVED=0
GH_LOGGED_IN=""
github_api_token() {
  (( GITHUB_API_TOKEN_RESOLVED == 0 )) || return 0
  GITHUB_API_TOKEN_RESOLVED=1
  local pattern='^[A-Za-z0-9_.-]+$' token
  if [[ -n ${GITHUB_TOKEN:-} ]]; then
    if [[ $GITHUB_TOKEN =~ $pattern ]]; then
      GITHUB_API_TOKEN=$GITHUB_TOKEN
      return 0
    fi
    warn "GITHUB_TOKEN is not a GitHub token (unexpected characters); ignoring it"
  fi
  if gh_logged_in && token=$(gh auth token --hostname github.com 2>/dev/null) && [[ $token =~ $pattern ]]; then
    GITHUB_API_TOKEN=$token
  fi
}

# gh_logged_in: gh is installed and has a github.com token (read locally; no
# network). Cached in GH_LOGGED_IN when called in the current shell.
gh_logged_in() {
  if [[ -z $GH_LOGGED_IN ]]; then
    if command -v gh >/dev/null 2>&1 && gh auth token --hostname github.com >/dev/null 2>&1; then
      GH_LOGGED_IN=yes
    else
      GH_LOGGED_IN=no
    fi
  fi
  [[ $GH_LOGGED_IN == yes ]]
}

# github_api_get <path>: print the body of https://api.github.com/<path>, or
# return one of the GITHUB_LOOKUP statuses. The token goes to curl on stdin
# (--config), never on the command line other processes can read; when it is
# refused the request is repeated anonymously.
github_api_get() {
  local api="https://api.github.com/$1" response="" code=""
  local -a curl_args=(--location --proto '=https' --tlsv1.2 --silent --show-error
    --connect-timeout 15 --max-time 60 --retry 3 -H 'Accept: application/vnd.github+json'
    --write-out '\n%{http_code}')
  if [[ -n $GITHUB_API_TOKEN ]]; then
    response=$(printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_API_TOKEN" |
      curl --config - "${curl_args[@]}" "$api" 2>/dev/null) || response=""
    code=${response##*$'\n'}
  fi
  if [[ $code != 200 && $code != 404 ]]; then
    response=$(curl "${curl_args[@]}" "$api") || response=""
    code=${response##*$'\n'}
  fi
  case $code in
    200) printf '%s\n' "${response%$'\n'*}" ;;
    404) return "$GITHUB_LOOKUP_NOT_FOUND" ;;
    403|429) return "$GITHUB_LOOKUP_REFUSED" ;;
    *) return "$GITHUB_LOOKUP_UNREACHABLE" ;;
  esac
}

# github_release_candidates < releases.json: "<tag><TAB><published_at>" for
# each release in a releases-list response that is neither a draft nor a
# prerelease and whose tag is a plain version (bun-v1.3.2, v1.39.0, 0.9.1;
# not 1.0.0-rc1 or a canary build), newest first. The JSON is split into
# "key": value tokens as in github_release_asset_record; tag_name starts each
# release, and its assets and author have none of these keys.
github_release_candidates() {
  awk '
    function value(text) {
      sub(/^"[^"]*"[ \t]*:[ \t]*"?/, "", text)
      sub(/"$/, "", text)
      return text
    }
    function flush(  version) {
      version = tag
      sub(/^[^0-9]*/, "", version)
      if (tag ~ /^[A-Za-z0-9._-]+$/ && version ~ /^[0-9]+([.][0-9]+)*$/ &&
          draft == "false" && pre == "false" &&
          published ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/)
        printf "%s\t%s\n", tag, published
      tag = ""; draft = ""; pre = ""; published = ""
    }
    BEGIN { RS = "[],{}[]" }
    {
      gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "")
      if ($0 ~ /^"tag_name"[ \t]*:/) { flush(); tag = value($0) }
      else if ($0 ~ /^"draft"[ \t]*:/) draft = value($0)
      else if ($0 ~ /^"prerelease"[ \t]*:/) pre = value($0)
      else if ($0 ~ /^"published_at"[ \t]*:/) published = value($0)
    }
    END { flush() }
  ' | LC_ALL=C sort -t "$(printf '\t')" -k2,2r
}

# github_release_tag_pick <owner/repo>: RELEASE_TAG and RELEASE_PUBLISHED
# become the newest release published at least MIN_RELEASE_AGE days ago,
# from the 30 newest. Returns a GITHUB_LOOKUP status when there is none.
# Cached per repository for the run; sets globals, so call it in the current
# shell, with `||` (a status is not an error).
RELEASE_TAG=""
RELEASE_PUBLISHED=""
RELEASE_URL=""
RELEASE_SHA=""
RELEASE_TAG_CACHE=""
RELEASE_ASSET_CACHE=""
github_release_tag_pick() {
  local repository=$1 line list status=0 key
  line=$(awk -F '\t' -v repository="$repository" '$1 == repository { print; exit }' <<< "$RELEASE_TAG_CACHE")
  if [[ -n $line ]]; then
    IFS=$'\t' read -r key RELEASE_TAG RELEASE_PUBLISHED <<< "$line"
    return 0
  fi
  release_age_cutoff
  github_api_token
  list=$(github_api_get "repos/$repository/releases?per_page=30") || status=$?
  case $status in
    0) ;;
    "$GITHUB_LOOKUP_NOT_FOUND") return "$GITHUB_LOOKUP_UNREACHABLE" ;;
    *) return "$status" ;;
  esac
  line=$(github_release_candidates <<< "$list" |
    awk -F '\t' -v cutoff="$RELEASE_CUTOFF_ISO" '$2 <= cutoff { print; exit }')
  [[ -n $line ]] || return "$GITHUB_LOOKUP_TOO_NEW"
  IFS=$'\t' read -r RELEASE_TAG RELEASE_PUBLISHED <<< "$line"
  RELEASE_TAG_CACHE+="$repository"$'\t'"$line"$'\n'
}

# release_asset_name <asset|template> <tag>: the asset name, with {version}
# (the tag's version: bun-v1.3.2 -> 1.3.2), {os} (Linux or Darwin) and {arch}
# (x86_64 or arm64) filled in.
release_asset_name() {
  local name=$1 version os arch
  local version_field='{version}' os_field='{os}' arch_field='{arch}'
  version=$(release_version "$2")
  os=$(uname -s)
  case $(uname -m) in
    arm64|aarch64) arch=arm64 ;;
    x86_64|amd64) arch=x86_64 ;;
    *) arch=$(uname -m) ;;
  esac
  name=${name//$version_field/$version}
  name=${name//$os_field/$os}
  name=${name//$arch_field/$arch}
  printf '%s\n' "$name"
}

# github_release_pick <owner/repo> <asset|template>: RELEASE_TAG,
# RELEASE_PUBLISHED, RELEASE_URL and RELEASE_SHA (hex, no prefix) become the
# asset in the release github_release_tag_pick chooses, read from
# releases/tags/<tag> with the digest GitHub computed for it. Same calling
# rules and statuses as github_release_tag_pick; a release without the asset,
# without a SHA-256 digest or with a download outside github.com dies.
github_release_pick() {
  local repository=$1 template=$2 asset line json record tag url digest status=0 key
  github_release_tag_pick "$repository" || return $?
  asset=$(release_asset_name "$template" "$RELEASE_TAG")
  line=$(awk -F '\t' -v key="$repository" -v asset="$asset" -v tag="$RELEASE_TAG" \
    '$1 == key && $2 == asset && $3 == tag { print; exit }' <<< "$RELEASE_ASSET_CACHE")
  if [[ -n $line ]]; then
    IFS=$'\t' read -r key key key RELEASE_URL RELEASE_SHA <<< "$line"
    return 0
  fi
  json=$(github_api_get "repos/$repository/releases/tags/$RELEASE_TAG") || status=$?
  case $status in
    0) ;;
    "$GITHUB_LOOKUP_NOT_FOUND") return "$GITHUB_LOOKUP_UNREACHABLE" ;;
    *) return "$status" ;;
  esac
  record=$(github_release_asset_record "$asset" <<< "$json") ||
    die "The $repository release $RELEASE_TAG has no $asset"
  IFS=$'\t' read -r tag url digest <<< "$record"
  [[ $tag == "$RELEASE_TAG" ]] || die "GitHub returned release $tag of $repository, not $RELEASE_TAG"
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "GitHub publishes no SHA-256 digest for $asset in $repository $tag"
  [[ $url == https://github.com/* ]] || die "Unexpected download URL for $asset in $repository: $url"
  RELEASE_URL=$url
  RELEASE_SHA=${digest#sha256:}
  RELEASE_ASSET_CACHE+="$repository"$'\t'"$asset"$'\t'"$RELEASE_TAG"$'\t'"$RELEASE_URL"$'\t'"$RELEASE_SHA"$'\n'
}

# release_attestation_published <owner/repo> <sha256>: gh is logged in and
# the repository publishes a GitHub attestation for that digest. Returns 2
# when GitHub cannot say (any answer but 200 or 404).
release_attestation_published() {
  local status=0
  gh_logged_in || return 1
  github_api_token
  github_api_get "repos/$1/attestations/sha256:$2" >/dev/null || status=$?
  case $status in
    0) return 0 ;;
    "$GITHUB_LOOKUP_NOT_FOUND") return 1 ;;
    *) return 2 ;;
  esac
}

# release_attestation_check <owner/repo> <file> <sha256>: after the digest
# check, when gh is logged in: a repository that publishes an attestation for
# the file must have it verify (gh attestation verify, which checks the
# Sigstore signature and that the repository's workflow built the file).
# One that publishes none (404) relies on the digest alone. RELEASE_VERIFIED_BY
# becomes attestation or digest.
RELEASE_VERIFIED_BY=""
release_attestation_check() {
  local repository=$1 file=$2 sha=$3 status=0 output
  RELEASE_VERIFIED_BY=digest
  release_attestation_published "$repository" "$sha" || status=$?
  case $status in
    0) ;;
    1) return 0 ;;
    *) die "Could not read $repository's attestations for ${file##*/} from GitHub; nothing was installed. Rerun, or log out of gh (gh auth logout) to rely on GitHub's SHA-256 digest alone." ;;
  esac
  if ! gh attestation verify --help >/dev/null 2>&1; then
    warn "$repository publishes attestations, but this gh cannot verify them (gh attestation needs gh 2.49 or later); relying on GitHub's SHA-256 digest"
    return 0
  fi
  if ! output=$(gh attestation verify "$file" --repo "$repository" 2>&1); then
    printf '%s\n' "$output" | sed 's/^/  gh: /' >&2
    die "${file##*/} does not verify against $repository's attestation; nothing was installed"
  fi
  RELEASE_VERIFIED_BY=attestation
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

# install_archive_binary <tool> <zip|tar.gz> <url> <sha256> <destination> <owner/repo> [extra...]:
# download the archive, verify its digest and (release_attestation_check) the
# repository's attestation, and install its <tool> executable at
# <destination>, and each extra executable beside it.
install_archive_binary() {
  local tool=$1 extension=$2 url=$3 sha=$4 destination=$5 repository=$6 temp archive binary extra
  shift 6
  temp=$(mktemp -d)
  track_temp "$temp"
  archive="$temp/$tool.$extension"
  download_verified "$url" "$sha" "$archive"
  release_attestation_check "$repository" "$archive" "$sha"
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
# or the directory. A release artifact is the newest release at least
# MIN_RELEASE_AGE days old (github_release_pick); that can be older than the
# installed copy, which is then replaced by it.
artifact_install() {
  local name=$1 directory=${2:-$HOME/.local/bin} url sha main record repository asset version present=1 executable
  local lookup_status=0
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
        say "Would install the newest $name release at least $MIN_RELEASE_AGE days old ($asset from github.com/$repository), checked against GitHub's SHA-256 digest and, when gh is logged in, its attestation"
        return 0
      fi
      github_release_pick "$repository" "$asset" || lookup_status=$?
      if (( lookup_status != 0 )); then
        artifact_release_unavailable "$name" "$repository" "$lookup_status"
        return 0
      fi
      version=$(release_version "$RELEASE_TAG")
      for executable in "${executables[@]}"; do
        [[ -x $directory/$executable ]] || present=0
      done
      if (( present )) && artifact_version_ok "$name" "$directory/$main" "$version"; then
        say "$name $version is already installed (the newest release at least $MIN_RELEASE_AGE days old, published $RELEASE_PUBLISHED)"
        return 0
      fi
      install_archive_binary "$main" "$ARTIFACT_ARCHIVE" "$RELEASE_URL" "$RELEASE_SHA" "$directory/$main" "$repository" \
        ${executables[1]+"${executables[@]:1}"}
      artifact_version_ok "$name" "$directory/$main" "$version" || die "$name does not report version $version after installation"
      say "Installed $name $version (published $RELEASE_PUBLISHED; verified by $RELEASE_VERIFIED_BY)" ;;
  esac
}

# artifact_release_unavailable <name> <owner/repo> <status>: no release could
# be picked (github_release_pick's status). A copy that is installed and
# verifies is kept with a warning: a GitHub outage, the API's rate limit or a
# run of very new releases must not fail a run that only re-checks tools.
# Without one, it dies, naming GITHUB_TOKEN when the API refused the request.
artifact_release_unavailable() {
  local name=$1 repository=$2 status=$3 reason
  case $status in
    "$GITHUB_LOOKUP_TOO_NEW") reason="none of $repository's 30 newest releases is at least $MIN_RELEASE_AGE days old" ;;
    "$GITHUB_LOOKUP_REFUSED") reason="GitHub refused the request (HTTP 403/429), most likely the anonymous API rate limit of 60 requests an hour" ;;
    *) reason="could not read $repository's releases from GitHub" ;;
  esac
  if artifact_verify "$name"; then
    warn "kept the installed $name: $reason"
    return 0
  fi
  case $status in
    "$GITHUB_LOOKUP_TOO_NEW") die "Could not install $name: $reason. Rerun with a smaller --min-release-age." ;;
    "$GITHUB_LOOKUP_REFUSED") die "Could not install $name: $reason. Set GITHUB_TOKEN (for example GITHUB_TOKEN=\$(gh auth token)), or log in with gh, and rerun." ;;
    *) die "Could not install $name: $reason; check the network and rerun" ;;
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
  fnm_node_runs "$fnm"
}

# fnm_node_runs <fnm>: run the default Node once and show why it does not
# start (a missing shared library such as libatomic, a wrong architecture).
# Verification only sees that the version check failed; the loader's message
# is what tells the user what to fix.
fnm_node_runs() {
  local output
  if ! output=$("$1" exec --using=default -- node --version 2>&1); then
    printf '%s\n' "$output" | sed 's/^/  node: /' >&2
    die "Node $RESOLVED_NODE_VERSION was installed but does not run; see the node output above"
  fi
}

node_version_ok() { [[ ${1:-} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# The Node release index, from FNM_NODE_DIST_MIRROR when set (fnm honours the
# same variable for its downloads), so a mirror serves both (ONB-10). It must
# be an https URL.
node_dist_index_url() {
  local base=${FNM_NODE_DIST_MIRROR:-https://nodejs.org/dist}
  printf '%s/index.tab\n' "${base%/}"
}

# node_lts_pick <cutoff-date> < index.tab: the newest release of the newest LTS
# major whose first LTS release (the oldest row of that major with an LTS
# codename) is dated on or before the cutoff (YYYY-MM-DD). A new LTS line
# waits the minimum release age; its patch releases, and the patches of the
# line already in use, do not. index.tab lists releases newest first; its
# columns are $1 version, $2 date and $10 the LTS codename ("-" when none).
node_lts_pick() {
  awk -F '\t' -v cutoff="$1" '
    NR == 1 || $10 == "-" || $10 == "" { next }
    $1 ~ /^v[0-9]+[.][0-9]+[.][0-9]+$/ && $2 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
      major = $1
      sub(/^v/, "", major)
      sub(/[.].*/, "", major)
      if (!(major in newest)) { newest[major] = $1; order[++count] = major }
      first[major] = $2
    }
    END {
      for (i = 1; i <= count; i++)
        if (first[order[i]] <= cutoff) { print newest[order[i]]; exit }
    }
  '
}

# resolve_node_version: RESOLVED_NODE_VERSION becomes the newest release of the
# newest LTS line at least MIN_RELEASE_AGE days old (node_lts_pick).
# Returns non-zero (does not die) so callers can degrade gracefully: `inspect`
# falls back to "resolve-during-apply". install_fnm adds its own `|| die`.
resolve_node_version() {
  [[ -z $RESOLVED_NODE_VERSION ]] || return 0
  local fnm_bin latest
  release_age_cutoff
  if command -v curl >/dev/null 2>&1; then
    # Timeouts matter here: this runs inside apply while the install lock is
    # held, and inside the otherwise read-only `inspect`, so a stalled
    # connection would hang the whole operation.
    latest=$(curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
      --connect-timeout 15 --max-time 30 \
      "$(node_dist_index_url)" 2>/dev/null | node_lts_pick "${RELEASE_CUTOFF_ISO%%T*}") || true
  fi
  if ! node_version_ok "${latest:-}"; then
    # fnm's LTS list has no dates, so this fallback (only when the index
    # cannot be read here) is not age-gated.
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

# ---------------------------------------------------------------------------
# Python and Ruby: the newest stable line, the same on every OS. Neither has an
# LTS, so the newest stable release is the target. As for Node, a new minor
# line waits MIN_RELEASE_AGE days, counted from its x.y.0 release; patch
# releases are installed at once.

# stable_version_lines < versions: "<major.minor><TAB><newest x.y.z>" for each
# line among plain x.y.z versions (no previews, release candidates or other
# implementations), newest line first.
stable_version_lines() {
  awk '/^[0-9]+[.][0-9]+[.][0-9]+$/' | LC_ALL=C sort -t . -k1,1nr -k2,2nr -k3,3nr |
    awk -F . '!seen[$1 "." $2]++ { printf "%s.%s\t%s\n", $1, $2, $0 }'
}

# uv_cpython_versions < uv-python-list.json: the version of every CPython
# build uv can download for this platform (`uv python list --only-downloads
# --output-format json`): the default variant only (not freethreaded or debug
# builds), one per line. Each JSON object is a record; its fields may come in
# any order.
uv_cpython_versions() {
  awk '
    BEGIN { RS = "}[ \t\r\n]*,[ \t\r\n]*[{]" }
    function field(name,   text) {
      if (!match($0, "\"" name "\"[ \t\r\n]*:[ \t\r\n]*\"[^\"]*\"")) return ""
      text = substr($0, RSTART, RLENGTH)
      sub(/^"[^"]*"[ \t\r\n]*:[ \t\r\n]*"/, "", text)
      sub(/"$/, "", text)
      return text
    }
    {
      variant = field("variant")
      if (field("implementation") == "cpython" && (variant == "" || variant == "default") &&
          field("key") !~ /[+]/)
        print field("version")
    }
  '
}

# python_release_date <x.y>: python.org's release date of Python x.y.0, as
# GitHub-style ISO UTC (2025-10-07T14:13:54Z), or fail.
python_release_date() {
  local json date pattern
  command -v curl >/dev/null 2>&1 || return 1
  json=$(curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
    --connect-timeout 15 --max-time 30 "${PYTHON_RELEASE_API}?name=Python%20$1.0" 2>/dev/null) || return 1
  date=$(awk '
    BEGIN { RS = "[],{}[]" }
    {
      gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "")
      if ($0 ~ /^"release_date"[ \t]*:/) {
        sub(/^"release_date"[ \t]*:[ \t]*"/, "")
        sub(/"$/, "")
        print
        exit
      }
    }
  ' <<< "$json")
  pattern='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}'
  [[ $date =~ $pattern ]] || return 1
  printf '%sZ\n' "${date:0:19}"
}

# python_default_version: the version ~/.local/bin/python3 reports (3.14.6).
python_default_version() {
  local version
  [[ -x $HOME/.local/bin/python3 ]] || return 1
  version=$("$HOME/.local/bin/python3" --version 2>&1) || return 1
  version=${version#Python }
  [[ $version =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || return 1
  printf '%s\n' "$version"
}

# pick_runtime_line <lines> <newest-line-date-status> <installed version>:
# shared by Python and Ruby. <lines> is stable_version_lines output; the
# status says whether the newest line's x.y.0 is old enough (old), too new
# (new) or of unknown age (unknown). Sets PICKED_LINE, PICKED_VERSION and
# PICKED_ORIGIN (latest-stable, or release-date-unknown when the previous line
# is used because the newest line's age could not be read). An installed
# version already on the newest line is never moved back to the previous one
# for want of a date.
PICKED_LINE=""
PICKED_VERSION=""
PICKED_ORIGIN=""
pick_runtime_line() {
  local lines=$1 status=$2 installed=$3 newest previous chosen
  newest=$(sed -n '1p' <<< "$lines")
  previous=$(sed -n '2p' <<< "$lines")
  [[ -n $newest ]] || return 1
  PICKED_ORIGIN="latest-stable"
  case $status in
    old) chosen=$newest ;;
    new) chosen=$previous ;;
    *)
      if [[ -n $installed && ${installed%.*} == "${newest%%$'\t'*}" ]]; then
        chosen=$newest
      else
        chosen=$previous
        PICKED_ORIGIN="release-date-unknown"
      fi ;;
  esac
  [[ -n $chosen ]] || return 1
  PICKED_LINE=${chosen%%$'\t'*}
  PICKED_VERSION=${chosen#*$'\t'}
}

# resolve_python_line: RESOLVED_PYTHON_LINE (3.14) and RESOLVED_PYTHON_VERSION
# (its newest patch uv offers) become the newest stable CPython line uv can
# download whose x.y.0 python.org released at least MIN_RELEASE_AGE days ago;
# PYTHON_SELECTION says how (pick_runtime_line). When python.org gives no date,
# the previous line, with a warning. Needs the uv the uv step installed. Once
# per run; sets globals, so call it in the current shell. Returns non-zero
# when uv cannot list its downloads.
RESOLVED_PYTHON_LINE=""
RESOLVED_PYTHON_VERSION=""
PYTHON_SELECTION=""
PYTHON_NEWEST_LINE=""
resolve_python_line() {
  [[ -z $RESOLVED_PYTHON_LINE ]] || return 0
  local uv lines date status=unknown
  uv=$(artifact_path uv)
  [[ -x $uv ]] || return 1
  lines=$("$uv" python list --only-downloads --output-format json 2>/dev/null | uv_cpython_versions | stable_version_lines) ||
    return 1
  [[ -n $lines ]] || return 1
  PYTHON_NEWEST_LINE=$(sed -n '1p' <<< "$lines")
  PYTHON_NEWEST_LINE=${PYTHON_NEWEST_LINE%%$'\t'*}
  release_age_cutoff
  if date=$(python_release_date "$PYTHON_NEWEST_LINE"); then
    if [[ $date > "$RELEASE_CUTOFF_ISO" ]]; then status=new; else status=old; fi
  fi
  pick_runtime_line "$lines" "$status" "$(python_default_version 2>/dev/null || true)" || return 1
  RESOLVED_PYTHON_LINE=$PICKED_LINE
  RESOLVED_PYTHON_VERSION=$PICKED_VERSION
  PYTHON_SELECTION=$PICKED_ORIGIN
}

# uv_python <arguments...>: `uv python <arguments>` with the uv the uv step
# installed, putting the python executables into ~/.local/bin (whatever
# XDG_BIN_HOME says). uv releases before 0.8 kept `--default` behind
# --preview: when uv asks for it, the command is repeated with it.
uv_python() {
  local uv output status=0
  uv=$(artifact_path uv)
  printf '+ uv python %s\n' "$*"
  output=$(UV_PYTHON_BIN_DIR="$HOME/.local/bin" "$uv" python "$@" 2>&1) || status=$?
  if (( status != 0 )) && [[ $output == *--preview* ]]; then
    status=0
    output=$(UV_PYTHON_BIN_DIR="$HOME/.local/bin" "$uv" python "$@" --preview 2>&1) || status=$?
  fi
  [[ -z $output ]] || printf '%s\n' "$output" | sed 's/^/  uv: /'
  return "$status"
}

# The cpython component: the newest stable CPython line (resolve_python_line)
# from uv, as the default python3 and python in ~/.local/bin. A full upgrade
# also moves the line to its newest patch (uv python upgrade).
install_cpython() {
  local uv status=0
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would install the newest stable CPython line at least $MIN_RELEASE_AGE days old with uv python install --default (python3 and python in ~/.local/bin)"
    return 0
  fi
  uv=$(artifact_path uv)
  [[ -x $uv ]] || die "uv is not installed at $uv; the cpython component needs the uv component"
  if ! resolve_python_line; then
    if verify_cpython; then
      warn "kept the installed Python: uv could not list the CPython builds it downloads"
      return 0
    fi
    die "Could not resolve the newest stable CPython line: uv could not list the CPython builds it downloads"
  fi
  if [[ $PYTHON_SELECTION == release-date-unknown ]]; then
    warn "python.org did not give the release date of Python $PYTHON_NEWEST_LINE.0, so its age is unknown; installing the previous line, Python $RESOLVED_PYTHON_LINE"
  fi
  say "Selected Python $RESOLVED_PYTHON_LINE (now $RESOLVED_PYTHON_VERSION; the newest stable line at least $MIN_RELEASE_AGE days old)"
  uv_python install --default "$RESOLVED_PYTHON_LINE" || status=$?
  (( status == 0 )) || die "uv could not install Python $RESOLVED_PYTHON_LINE (status $status)"
  if [[ $FULL_UPGRADE -eq 1 ]]; then
    uv_python upgrade "$RESOLVED_PYTHON_LINE" || status=$?
    (( status == 0 )) || die "uv could not upgrade Python $RESOLVED_PYTHON_LINE (status $status)"
  fi
}

# python_default_kept: print the installed python3 version when this run
# leaves it alone (no full upgrade; the step is recorded and verifies).
python_default_kept() {
  [[ $FULL_UPGRADE -eq 0 ]] && state_done cpython && verify_step cpython || return 1
  python_default_version
}

# Ruby, compiled by rbenv install (ruby-build) after install_rbenv's
# checkouts, under rbenv_root (where the rbenv step puts rbenv).
rbenv_root() { printf '%s\n' "$HOME/.rbenv"; }

# ruby_line_added <x.y>: when ruby-build gained the x.y.0 definition (epoch
# seconds of the commit that added share/ruby-build/x.y.0), from the local
# checkout's history.
ruby_line_added() {
  local added
  added=$(git -C "$(rbenv_root)/plugins/ruby-build" log --diff-filter=A --format=%ct -- "share/ruby-build/$1.0" 2>/dev/null |
    tail -n 1) || return 1
  [[ $added =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$added"
}

# ruby_global_version: rbenv's global Ruby (its version file), when rbenv
# installed it and it runs.
ruby_global_version() {
  local root version
  root=$(rbenv_root)
  [[ -f $root/version ]] || return 1
  version=$(sed -n '1p' "$root/version")
  [[ -n $version && $version != system && $version != */* ]] || return 1
  [[ -x $root/versions/$version/bin/ruby ]] || return 1
  "$root/versions/$version/bin/ruby" -e 'exit 0' >/dev/null 2>&1 || return 1
  printf '%s\n' "$version"
}

# resolve_ruby_version: RESOLVED_RUBY_VERSION becomes the newest stable Ruby
# (x.y.z) ruby-build has a definition for, on the newest line whose x.y.0
# definition is at least MIN_RELEASE_AGE days old (ruby-build itself follows
# its newest tag at once, so patch releases are not delayed); RUBY_SELECTION
# as for Python. Needs the ruby-build checkout. Once per run, in the current
# shell.
RESOLVED_RUBY_VERSION=""
RUBY_SELECTION=""
RUBY_NEWEST_LINE=""
resolve_ruby_version() {
  [[ -z $RESOLVED_RUBY_VERSION ]] || return 0
  local build lines added status=unknown
  build="$(rbenv_root)/plugins/ruby-build"
  [[ -x $build/bin/ruby-build ]] || return 1
  lines=$("$build/bin/ruby-build" --definitions 2>/dev/null | stable_version_lines) || return 1
  [[ -n $lines ]] || return 1
  RUBY_NEWEST_LINE=$(sed -n '1p' <<< "$lines")
  RUBY_NEWEST_LINE=${RUBY_NEWEST_LINE%%$'\t'*}
  release_age_cutoff
  if added=$(ruby_line_added "$RUBY_NEWEST_LINE"); then
    if (( added > RELEASE_CUTOFF_EPOCH )); then status=new; else status=old; fi
  fi
  pick_runtime_line "$lines" "$status" "$(ruby_global_version 2>/dev/null || true)" || return 1
  RESOLVED_RUBY_VERSION=$PICKED_VERSION
  RUBY_SELECTION=$PICKED_ORIGIN
}

# RUBY_RESULT: this run's Ruby outcome, recorded in the state file's
# diagnostic column for rbenv: ruby:<version>, or ruby-failed:<version> when
# the compile failed. A failed compile only warns: rbenv itself works, and
# verify_rbenv accepts a recorded failure, so a reconcile does not compile
# again every time; a full upgrade (which re-runs rbenv) retries.
RUBY_RESULT=""
install_ruby() {
  local rbenv version
  rbenv="$(rbenv_root)/bin/rbenv"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "Would compile the newest stable Ruby at least $MIN_RELEASE_AGE days old with rbenv install and make it rbenv's global version"
    return 0
  fi
  if ! resolve_ruby_version; then
    if ruby_global_version >/dev/null; then
      warn "kept the installed Ruby: ruby-build did not list its definitions"
      return 0
    fi
    die "Could not read Ruby's versions from ruby-build in $(rbenv_root)/plugins/ruby-build"
  fi
  version=$RESOLVED_RUBY_VERSION
  if [[ $RUBY_SELECTION == release-date-unknown ]]; then
    warn "ruby-build's history does not say when Ruby $RUBY_NEWEST_LINE.0 was added, so its age is unknown; installing the previous line, Ruby $version"
  fi
  say "Selected Ruby $version (the newest stable release on the newest line at least $MIN_RELEASE_AGE days old)"
  if ! run env RBENV_ROOT="$(rbenv_root)" "$rbenv" install --skip-existing "$version"; then
    warn "Ruby $version did not compile (see ruby-build's output above); rbenv is installed without it. Install what the build lacked, then run a full upgrade (bash install.sh reconcile --yes --full-upgrade) to try again."
    RUBY_RESULT="ruby-failed:$version"
    return 0
  fi
  run env RBENV_ROOT="$(rbenv_root)" "$rbenv" global "$version"
  RUBY_RESULT="ruby:$version"
}

# ruby_compile_failed: the newest recorded Ruby outcome (this run's, else
# the state file's) is a failed compile.
ruby_compile_failed() {
  local detail=$RUBY_RESULT
  [[ -n $detail ]] || detail=$(state_detail rbenv)
  [[ $detail == ruby-failed:* ]]
}

# ruby_default_kept: print rbenv's global Ruby when this run leaves it alone.
ruby_default_kept() {
  [[ $FULL_UPGRADE -eq 0 ]] && state_done rbenv && verify_step rbenv || return 1
  ruby_global_version
}

# uv and uvx; their Zsh completions are cached by zsh/path/uv.zsh (MI-13).
install_uv() { artifact_install uv; }

fnm_exec() {
  "$(fnm_path)" exec --using=default -- "$@"
}
