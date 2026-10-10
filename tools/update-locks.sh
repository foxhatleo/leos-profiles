#!/usr/bin/env bash
# Propose updates to installer/lock.sh from upstream release metadata, and
# verify every candidate against the integrity data its upstream publishes
# before it can become a pin (SEC-6). See docs/development.md, "Updating
# pinned artifacts".
#
#   bash tools/update-locks.sh [--only NAME[,NAME...]] [--write]
#                              [--allow-unverified] [--lock FILE]
#
# Without --write it changes nothing: it prints, per artifact, the candidate
# and what verified it, then a diff of lock.sh. With --write it rewrites the
# lock file in place, and only when every selected candidate verified.
#
# Exit status: 0 done (or nothing to update), 1 a candidate failed
# verification (nothing written), 2 usage or environment error.
#
# Needs gh (authenticated, read-only API use), curl, jq, openssl, gpg (for
# bun), and shasum or sha256sum. Bash 3.2 compatible.

set -Eeuo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
LOCK=$ROOT/installer/lock.sh
WRITE=0
ONLY=
ALLOW_UNVERIFIED=0

# Bun signs SHASUMS256.txt with this key; tools/keys/bun-release.asc is the
# public key oven-sh/bun embeds in dockerhub/debian/Dockerfile (at commit
# c7b06d94bac19817ba34b6677bb1099fb4f6d2be) to verify the same file.
BUN_KEY_FILE=$ROOT/tools/keys/bun-release.asc
BUN_KEY_FINGERPRINT=F3DCC08A8572C0749B3E18888EAB4D40A7B22B59
NPM_REGISTRY=https://registry.npmjs.org

# name|kind|lock prefix|upstream (GitHub repository or npm package)|integrity
#   release: GitHub release assets; integrity is what besides GitHub's own
#            asset digest vouches for them: bun-signature, sha256-files, or
#            digest (only GitHub's digest)
#   nerd-fonts: the release's SHA-256.txt, checked against every asset digest
#   npm: registry tarball, dist.integrity and the registry signature
#   raw: a file at a commit of a GitHub repository (git blob hash)
#   git: a checkout at a commit, fast-forward from the current pin only
ARTIFACTS='bun|release|BUN|oven-sh/bun|bun-signature
fnm|release|FNM|Schniz/fnm|digest
starship|release|STARSHIP|starship/starship|sha256-files
uv|release|UV|astral-sh/uv|sha256-files
nerd-fonts|nerd-fonts|NERD_FONTS|ryanoasis/nerd-fonts|sha256-list
yarn|npm|YARN|yarn|npm
pnpm|npm|PNPM|pnpm|npm
rpatool|raw|RPATOOL|Shizmob/rpatool|git-blob
homebrew-install|raw|HOMEBREW_INSTALL|Homebrew/install|git-blob
pyenv|git|PYENV||commit
rbenv|git|RBENV||commit
ruby-build|git|RUBY_BUILD||commit
zsh-autosuggestions|git|ZSH_AUTOSUGGESTIONS||commit
zsh-syntax-highlighting|git|ZSH_SYNTAX_HIGHLIGHTING||commit
zsh-completions|git|ZSH_COMPLETIONS||commit
fzf-tab|git|FZF_TAB||commit'

usage() {
  sed -n '7,9p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

say() { printf '%s\n' "$*"; }
die() { printf 'update-locks: %s\n' "$*" >&2; exit 2; }

REFUSED=0
refuse() {
  printf '  REFUSED: %s\n' "$*"
  REFUSED=1
}

while (( $# )); do
  case $1 in
    --write) WRITE=1 ;;
    --allow-unverified) ALLOW_UNVERIFIED=1 ;;
    --only) shift; ONLY=${1:-}; [[ -n $ONLY ]] || usage ;;
    --only=*) ONLY=${1#--only=} ;;
    --lock) shift; LOCK=${1:-}; [[ -n $LOCK ]] || usage ;;
    -h|--help) usage 0 ;;
    *) usage ;;
  esac
  shift
done
[[ -f $LOCK ]] || die "no lock file at $LOCK"

# Test fixtures may substitute the bun signing key; say so loudly.
if [[ -n ${UPDATE_LOCKS_TEST_BUN_KEY_FILE:-} ]]; then
  BUN_KEY_FILE=$UPDATE_LOCKS_TEST_BUN_KEY_FILE
  BUN_KEY_FINGERPRINT=${UPDATE_LOCKS_TEST_BUN_FINGERPRINT:-}
  say "WARNING: using the test bun signing key $BUN_KEY_FINGERPRINT"
fi
NPM_REGISTRY=${UPDATE_LOCKS_TEST_NPM_REGISTRY:-$NPM_REGISTRY}

for tool in gh curl jq openssl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
if command -v shasum >/dev/null 2>&1; then
  sha256_file() { shasum -a 256 "$1" | awk '{print $1}'; }
  sha1_stdin() { shasum -a 1 | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256_file() { sha256sum "$1" | awk '{print $1}'; }
  sha1_stdin() { sha1sum | awk '{print $1}'; }
else
  die "shasum or sha256sum is required"
fi

WORK=$(mktemp -d)
cleanup() {
  [[ -z ${GNUPGHOME_TMP:-} ]] || gpgconf --homedir "$GNUPGHOME_TMP" --kill all >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
NEW_LOCK=$WORK/lock.sh
cp "$LOCK" "$NEW_LOCK"

# --- lock file access -------------------------------------------------------

# lock_get NAME: the value of `readonly NAME="value"` in the current lock.
lock_get() {
  sed -n "s/^readonly $1=\"\\(.*\\)\"\$/\\1/p" "$LOCK"
}

lock_names() {
  sed -n 's/^readonly \([A-Z0-9_]*\)=.*/\1/p' "$LOCK"
}

# lock_set NAME VALUE: rewrite one assignment in the candidate lock. lock.sh is
# sourced by the installer, so a value is only ever URL, version, digest or
# engine characters: never a quote, `$`, backquote or whitespace.
lock_set() {
  local name=$1 value=$2
  [[ $value =~ ^[A-Za-z0-9._:/@%+=~\>-]+$ ]] || { refuse "unsafe value for $name: $value"; return 1; }
  grep -q "^readonly $name=" "$NEW_LOCK" || { refuse "$name is not in the lock"; return 1; }
  awk -v name="$name" -v value="$value" '
    index($0, "readonly " name "=") == 1 { print "readonly " name "=\"" value "\""; next }
    { print }
  ' "$NEW_LOCK" > "$NEW_LOCK.tmp"
  mv -f "$NEW_LOCK.tmp" "$NEW_LOCK"
}

# --- upstream access ---------------------------------------------------------

fetch() {
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 \
    --silent --show-error --output "$2" "$1"
}

gh_json() {
  gh api "$1" > "$2"
}

valid_tag() { [[ $1 =~ ^[A-Za-z0-9._+-]+$ ]]; }
valid_sha256() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
valid_commit() { [[ $1 =~ ^[0-9a-f]{40}$ ]]; }

# asset_field <release.json> <asset name> <jq field>
asset_field() {
  jq -r --arg name "$2" ".assets[] | select(.name == \$name) | .$3 // empty" "$1"
}

# github_digest_check <release.json> <asset> <sha256> <required 0|1>
github_digest_check() {
  local digest
  digest=$(asset_field "$1" "$2" digest)
  if [[ -z $digest ]]; then
    if [[ $4 == 1 && $ALLOW_UNVERIFIED -eq 0 ]]; then
      refuse "$2: GitHub publishes no digest and there is no other integrity data (--allow-unverified accepts it)"
      return 1
    fi
    say "  note: $2 has no GitHub asset digest"
    return 0
  fi
  if [[ $digest != "sha256:$3" ]]; then
    refuse "$2: SHA-256 $3 does not match GitHub's asset digest $digest"
    return 1
  fi
  say "  ok: $2 matches GitHub's asset digest"
}

# bun_verified_sums <release.json> <tag> <dest>: SHASUMS256.txt as signed by
# the pinned key, or fail.
bun_verified_sums() {
  local release=$1 tag=$2 dest=$3 dir=$WORK/bun-sums status
  command -v gpg >/dev/null 2>&1 || { refuse "gpg is required to verify bun's SHASUMS256.txt.asc"; return 1; }
  mkdir -p "$dir"
  if [[ -z ${GNUPGHOME_TMP:-} ]]; then
    GNUPGHOME_TMP=$(mktemp -d "$WORK/gnupg.XXXXXX")
    chmod 700 "$GNUPGHOME_TMP"
    gpg --homedir "$GNUPGHOME_TMP" --batch --quiet --import "$BUN_KEY_FILE" 2>/dev/null ||
      { refuse "could not import $BUN_KEY_FILE"; return 1; }
    if ! gpg --homedir "$GNUPGHOME_TMP" --batch --with-colons --fingerprint 2>/dev/null |
        grep -q "^fpr:::::::::$BUN_KEY_FINGERPRINT:"; then
      refuse "$BUN_KEY_FILE is not the key $BUN_KEY_FINGERPRINT"
      return 1
    fi
  fi
  [[ -n $(asset_field "$release" SHASUMS256.txt.asc name) ]] ||
    { refuse "bun $tag publishes no SHASUMS256.txt.asc"; return 1; }
  fetch "$(asset_field "$release" SHASUMS256.txt.asc browser_download_url)" "$dir/SHASUMS256.txt.asc" ||
    { refuse "download of SHASUMS256.txt.asc failed"; return 1; }
  github_digest_check "$release" SHASUMS256.txt.asc "$(sha256_file "$dir/SHASUMS256.txt.asc")" 0 || return 1
  status=$(gpg --homedir "$GNUPGHOME_TMP" --batch --status-fd 1 --output "$dest" \
    --verify "$dir/SHASUMS256.txt.asc" 2>/dev/null) || true
  if ! printf '%s\n' "$status" | grep -Eq "^\[GNUPG:\] VALIDSIG .* $BUN_KEY_FINGERPRINT\$"; then
    rm -f "$dest"
    refuse "bun $tag: SHASUMS256.txt.asc has no valid signature by $BUN_KEY_FINGERPRINT"
    return 1
  fi
  say "  ok: SHASUMS256.txt signed by $BUN_KEY_FINGERPRINT"
}

# --- artifact kinds ---------------------------------------------------------

# update_release <name> <prefix> <repository> <integrity>
update_release() {
  local name=$1 prefix=$2 repo=$3 integrity=$4
  local version tag tag_prefix release new_tag new_version var url asset new_asset new_url sha
  local dir=$WORK/$name sums=$WORK/$name/SHASUMS256.verified expected sumline
  local -a url_vars
  version=$(lock_get "${prefix}_VERSION")
  url_vars=()
  while IFS= read -r var; do url_vars+=("$var"); done < <(lock_names | grep -E "^${prefix}_([A-Z0-9]+_)*URL\$")
  (( ${#url_vars[@]} )) || { refuse "$name: no ${prefix}_*_URL in the lock"; return 1; }
  url=$(lock_get "${url_vars[0]}")
  [[ $url =~ ^https://github\.com/$repo/releases/download/([^/]+)/[^/]+$ ]] ||
    { refuse "$name: ${url_vars[0]} is not a $repo release asset URL"; return 1; }
  tag=${BASH_REMATCH[1]}
  tag_prefix=${tag%"$version"}
  [[ $tag_prefix$version == "$tag" ]] || { refuse "$name: tag $tag does not end in version $version"; return 1; }
  mkdir -p "$dir"
  release=$dir/release.json
  gh_json "repos/$repo/releases/latest" "$release" || { refuse "$name: no latest release for $repo"; return 1; }
  new_tag=$(jq -r '.tag_name // empty' "$release")
  valid_tag "$new_tag" || { refuse "$name: unexpected tag name: $new_tag"; return 1; }
  [[ $new_tag == "$tag_prefix"* ]] || { refuse "$name: tag $new_tag does not start with $tag_prefix"; return 1; }
  new_version=${new_tag#"$tag_prefix"}
  [[ $new_version =~ ^[0-9][0-9A-Za-z.+-]*$ ]] || { refuse "$name: unexpected version $new_version"; return 1; }
  if [[ $new_tag == "$tag" ]]; then
    say "$name: $version is the latest release"
    return 0
  fi
  say "$name: $version -> $new_version ($repo $new_tag)"
  if [[ $integrity == bun-signature ]]; then
    bun_verified_sums "$release" "$new_tag" "$sums" || return 1
  fi
  for var in "${url_vars[@]}"; do
    url=$(lock_get "$var")
    asset=${url##*/}
    new_asset=${asset//"$version"/"$new_version"}
    new_url=https://github.com/$repo/releases/download/$new_tag/$new_asset
    [[ $(asset_field "$release" "$new_asset" browser_download_url) == "$new_url" ]] ||
      { refuse "$name: $new_tag has no asset $new_asset"; continue; }
    fetch "$new_url" "$dir/$new_asset" || { refuse "$name: download failed: $new_url"; continue; }
    sha=$(sha256_file "$dir/$new_asset")
    if [[ $integrity == digest ]]; then
      github_digest_check "$release" "$new_asset" "$sha" 1 || continue
    else
      github_digest_check "$release" "$new_asset" "$sha" 0 || continue
    fi
    case $integrity in
      sha256-files)
        [[ -n $(asset_field "$release" "$new_asset.sha256" name) ]] ||
          { refuse "$name: $new_tag publishes no $new_asset.sha256"; continue; }
        fetch "$new_url.sha256" "$dir/$new_asset.sha256" || { refuse "$name: download failed: $new_url.sha256"; continue; }
        expected=$(grep -Eo '[0-9a-fA-F]{64}' "$dir/$new_asset.sha256" | head -n 1 | tr 'A-F' 'a-f')
        [[ $expected == "$sha" ]] ||
          { refuse "$new_asset: SHA-256 $sha does not match $new_asset.sha256 ($expected)"; continue; }
        say "  ok: $new_asset matches $new_asset.sha256" ;;
      bun-signature)
        sumline=$(awk -v want="$new_asset" '$2 == want || $2 == "*" want { print tolower($1); exit }' "$sums")
        [[ $sumline == "$sha" ]] ||
          { refuse "$new_asset: SHA-256 $sha does not match the signed SHASUMS256.txt (${sumline:-absent})"; continue; }
        say "  ok: $new_asset matches the signed SHASUMS256.txt" ;;
    esac
    lock_set "$var" "$new_url" || continue
    lock_set "${var%_URL}_SHA256" "$sha" || continue
    say "  $var -> $new_url"
    say "  ${var%_URL}_SHA256 -> $sha"
  done
  lock_set "${prefix}_VERSION" "$new_version" || return 1
}

# update_nerd_fonts <name> <prefix> <repository>
update_nerd_fonts() {
  local name=$1 prefix=$2 repo=$3 version new_tag release dir=$WORK/$1 sha line digest file mismatch=0 matched=0
  version=$(lock_get "${prefix}_VERSION")
  mkdir -p "$dir"
  release=$dir/release.json
  gh_json "repos/$repo/releases/latest" "$release" || { refuse "$name: no latest release for $repo"; return 1; }
  new_tag=$(jq -r '.tag_name // empty' "$release")
  valid_tag "$new_tag" || { refuse "$name: unexpected tag name: $new_tag"; return 1; }
  if [[ $new_tag == "$version" ]]; then
    say "$name: $version is the latest release"
    return 0
  fi
  say "$name: $version -> $new_tag ($repo)"
  [[ -n $(asset_field "$release" SHA-256.txt name) ]] || { refuse "$name: $new_tag has no SHA-256.txt"; return 1; }
  fetch "https://github.com/$repo/releases/download/$new_tag/SHA-256.txt" "$dir/SHA-256.txt" ||
    { refuse "$name: SHA-256.txt download failed"; return 1; }
  sha=$(sha256_file "$dir/SHA-256.txt")
  github_digest_check "$release" SHA-256.txt "$sha" 1 || return 1
  # Every font archive the list names must match GitHub's own digest for it.
  while IFS= read -r line; do
    digest=$(printf '%s\n' "$line" | awk '{print tolower($1)}')
    file=$(printf '%s\n' "$line" | awk '{print $NF}')
    file=${file#\*}
    valid_sha256 "$digest" || continue
    case $(asset_field "$release" "$file" digest) in
      "") ;;
      "sha256:$digest") matched=$((matched + 1)) ;;
      *) refuse "$name: SHA-256.txt lists $digest for $file, GitHub's digest differs"; mismatch=1 ;;
    esac
  done < "$dir/SHA-256.txt"
  (( ! mismatch )) || return 1
  (( matched )) || { refuse "$name: no SHA-256.txt entry could be checked against GitHub's digests"; return 1; }
  say "  ok: SHA-256.txt agrees with GitHub's digest for $matched archive(s)"
  lock_set "${prefix}_VERSION" "$new_tag" || return 1
  lock_set "${prefix}_RELEASE_URL" "https://github.com/$repo/releases/download/$new_tag" || return 1
  lock_set "${prefix}_CHECKSUMS_SHA256" "$sha" || return 1
  say "  ${prefix}_CHECKSUMS_SHA256 -> $sha"
}

# npm_signature_ok <package> <version> <integrity> <metadata.json>: a registry
# signature over "<package>@<version>:<integrity>" (what `npm audit
# signatures` checks), made with a key the registry publishes.
npm_signature_ok() {
  local package=$1 version=$2 integrity=$3 meta=$4 dir=$WORK/npm-$1 keys keyid sig key ok=0
  mkdir -p "$dir"
  keys=$dir/keys.json
  fetch "$NPM_REGISTRY/-/npm/v1/keys" "$keys" || { refuse "$package: could not fetch the registry keys"; return 1; }
  printf '%s' "$package@$version:$integrity" > "$dir/message"
  while IFS=$'\t' read -r keyid sig; do
    [[ -n $keyid ]] || continue
    key=$(jq -r --arg id "$keyid" '.keys[] | select(.keyid == $id) | .key // empty' "$keys")
    [[ -n $key ]] || continue
    printf '%s' "$key" | openssl base64 -d -A > "$dir/key.der"
    printf '%s' "$sig" | openssl base64 -d -A > "$dir/sig.der"
    openssl pkey -pubin -inform DER -in "$dir/key.der" -out "$dir/key.pem" 2>/dev/null || continue
    if openssl dgst -sha256 -verify "$dir/key.pem" -signature "$dir/sig.der" "$dir/message" >/dev/null 2>&1; then
      say "  ok: registry signature by $keyid"
      ok=1
      break
    fi
  done < <(jq -r '.dist.signatures[]? | [.keyid, .sig] | @tsv' "$meta")
  (( ok )) && return 0
  if (( ALLOW_UNVERIFIED )); then
    say "  note: no verifiable registry signature (accepted: --allow-unverified)"
    return 0
  fi
  refuse "$package@$version: no registry signature verifies"
  return 1
}

# update_npm <name> <prefix> <package>
update_npm() {
  local name=$1 prefix=$2 package=$3 version meta new_version tarball integrity dir=$WORK/$1
  local actual sha engine old_engine scripts
  version=$(lock_get "${prefix}_VERSION")
  mkdir -p "$dir"
  meta=$dir/latest.json
  fetch "$NPM_REGISTRY/$package/latest" "$meta" || { refuse "$name: registry metadata unavailable"; return 1; }
  new_version=$(jq -r '.version // empty' "$meta")
  [[ $new_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { refuse "$name: unexpected version $new_version"; return 1; }
  if [[ $new_version == "$version" ]]; then
    say "$name: $version is the latest release"
    return 0
  fi
  say "$name: $version -> $new_version (npm $package)"
  tarball=$(jq -r '.dist.tarball // empty' "$meta")
  [[ $tarball == "https://registry.npmjs.org/$package/-/$package-$new_version.tgz" ]] ||
    { refuse "$name: unexpected tarball URL $tarball"; return 1; }
  integrity=$(jq -r '.dist.integrity // empty' "$meta")
  [[ $integrity == sha512-* ]] || { refuse "$name: no sha512 dist.integrity"; return 1; }
  fetch "$tarball" "$dir/package.tgz" || { refuse "$name: download failed: $tarball"; return 1; }
  actual=sha512-$(openssl dgst -sha512 -binary "$dir/package.tgz" | openssl base64 -A)
  [[ $actual == "$integrity" ]] || { refuse "$name: tarball is $actual, the registry says $integrity"; return 1; }
  say "  ok: tarball matches dist.integrity"
  npm_signature_ok "$package" "$new_version" "$integrity" "$meta" || return 1
  # The installer runs npm with --ignore-scripts: point out lifecycle scripts.
  scripts=$(tar -xOf "$dir/package.tgz" package/package.json 2>/dev/null |
    jq -r '.scripts // {} | keys[] | select(. == "preinstall" or . == "install" or . == "postinstall")' 2>/dev/null || true)
  [[ -z $scripts ]] ||
    say "  note: $package $new_version declares ${scripts//$'\n'/, }; the installer skips them (--ignore-scripts): check it still works without"
  engine=$(tar -xOf "$dir/package.tgz" package/package.json 2>/dev/null | jq -r '.engines.node // empty' 2>/dev/null || true)
  old_engine=$(lock_get "${prefix}_NODE_ENGINE")
  if [[ $engine != "$old_engine" ]]; then
    [[ $engine =~ ^\>=[0-9]+(\.[0-9]+){0,2}$ ]] ||
      { refuse "$name: engines.node \"$engine\" is not a >=X[.Y[.Z]] range node_satisfies_engine supports"; return 1; }
    say "  note: engines.node $old_engine -> $engine: update the Node selection tests (tests/node-test.sh) too"
    lock_set "${prefix}_NODE_ENGINE" "$engine" || return 1
  fi
  sha=$(sha256_file "$dir/package.tgz")
  lock_set "${prefix}_VERSION" "$new_version" || return 1
  lock_set "${prefix}_URL" "$tarball" || return 1
  lock_set "${prefix}_SHA256" "$sha" || return 1
  say "  ${prefix}_SHA256 -> $sha"
}

# fast_forward_ok <repository> <old> <new>: the new commit descends from the pin.
fast_forward_ok() {
  local status
  status=$(gh api "repos/$1/compare/$2...$3" | jq -r '.status // empty') || status=
  case $status in
    ahead) return 0 ;;
    *) refuse "$1: $3 is not a fast-forward of the pinned $2 (${status:-unknown})"; return 1 ;;
  esac
}

# update_raw <name> <prefix> <repository>
update_raw() {
  local name=$1 prefix=$2 repo=$3 url commit file new_commit new_url blob expected sha dir=$WORK/$1
  url=$(lock_get "${prefix}_URL")
  [[ $url =~ ^https://raw\.githubusercontent\.com/$repo/([0-9a-f]{40})/(.+)$ ]] ||
    { refuse "$name: ${prefix}_URL is not a raw $repo file at a commit"; return 1; }
  commit=${BASH_REMATCH[1]}
  file=${BASH_REMATCH[2]}
  mkdir -p "$dir"
  gh_json "repos/$repo/commits/HEAD" "$dir/head.json" || { refuse "$name: cannot read $repo HEAD"; return 1; }
  new_commit=$(jq -r '.sha // empty' "$dir/head.json")
  valid_commit "$new_commit" || { refuse "$name: unexpected commit $new_commit"; return 1; }
  if [[ $new_commit == "$commit" ]]; then
    say "$name: ${commit:0:12} is $repo's HEAD"
    return 0
  fi
  say "$name: ${commit:0:12} -> ${new_commit:0:12} ($repo $file)"
  fast_forward_ok "$repo" "$commit" "$new_commit" || return 1
  new_url=https://raw.githubusercontent.com/$repo/$new_commit/$file
  fetch "$new_url" "$dir/file" || { refuse "$name: download failed: $new_url"; return 1; }
  # Git's blob id of what was downloaded must be the one the commit records.
  blob=$({ printf 'blob %s\0' "$(wc -c < "$dir/file" | tr -d ' ')"; cat "$dir/file"; } | sha1_stdin)
  gh_json "repos/$repo/contents/$file?ref=$new_commit" "$dir/contents.json" ||
    { refuse "$name: cannot read $file at $new_commit"; return 1; }
  expected=$(jq -r '.sha // empty' "$dir/contents.json")
  [[ $blob == "$expected" ]] || { refuse "$name: downloaded $file is blob $blob, the commit has $expected"; return 1; }
  say "  ok: $file is the blob $repo records at ${new_commit:0:12}"
  sha=$(sha256_file "$dir/file")
  lock_set "${prefix}_URL" "$new_url" || return 1
  lock_set "${prefix}_SHA256" "$sha" || return 1
  say "  ${prefix}_SHA256 -> $sha"
}

# update_git <name> <prefix>
update_git() {
  local name=$1 prefix=$2 repository repo commit new_commit dir=$WORK/$1 verified
  repository=$(lock_get "${prefix}_REPOSITORY")
  commit=$(lock_get "${prefix}_COMMIT")
  [[ $repository =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\.git$ ]] ||
    { refuse "$name: ${prefix}_REPOSITORY is not a GitHub repository URL"; return 1; }
  repo=${BASH_REMATCH[1]}
  mkdir -p "$dir"
  gh_json "repos/$repo/commits/HEAD" "$dir/head.json" || { refuse "$name: cannot read $repo HEAD"; return 1; }
  new_commit=$(jq -r '.sha // empty' "$dir/head.json")
  valid_commit "$new_commit" || { refuse "$name: unexpected commit $new_commit"; return 1; }
  if [[ $new_commit == "$commit" ]]; then
    say "$name: ${commit:0:12} is $repo's HEAD"
    return 0
  fi
  say "$name: ${commit:0:12} -> ${new_commit:0:12} ($repo)"
  fast_forward_ok "$repo" "$commit" "$new_commit" || return 1
  verified=$(jq -r '.commit.verification.verified // false' "$dir/head.json")
  say "  ok: fast-forward from the pin; GitHub signature verified: $verified"
  lock_set "${prefix}_COMMIT" "$new_commit" || return 1
}

# --- main ---------------------------------------------------------------------

# Every lock variable must belong to an artifact this tool knows how to check.
known_prefixes=$(printf '%s\n' "$ARTIFACTS" | cut -d'|' -f3)
while IFS= read -r var; do
  found=0
  while IFS= read -r prefix; do
    [[ $var == "${prefix}_"* ]] && { found=1; break; }
  done <<< "$known_prefixes"
  (( found )) || die "installer/lock.sh has $var, which no artifact here covers; add it to tools/update-locks.sh"
done < <(lock_names)

if [[ -n $ONLY ]]; then
  for name in ${ONLY//,/ }; do
    printf '%s\n' "$ARTIFACTS" | cut -d'|' -f1 | grep -qx -- "$name" || die "unknown artifact: $name"
  done
fi

selected=0
while IFS='|' read -r name kind prefix upstream integrity; do
  if [[ -n $ONLY && ",$ONLY," != *",$name,"* ]]; then continue; fi
  if ! lock_names | grep -q "^${prefix}_"; then
    [[ -z $ONLY ]] || die "$name is not in $LOCK"
    continue
  fi
  selected=$((selected + 1))
  case $kind in
    release) update_release "$name" "$prefix" "$upstream" "$integrity" || true ;;
    nerd-fonts) update_nerd_fonts "$name" "$prefix" "$upstream" || true ;;
    npm) update_npm "$name" "$prefix" "$upstream" || true ;;
    raw) update_raw "$name" "$prefix" "$upstream" || true ;;
    git) update_git "$name" "$prefix" || true ;;
  esac
done <<< "$ARTIFACTS"
(( selected )) || die "no artifact selected"

say ""
if (( REFUSED )); then
  say "Refusing to change $LOCK: a candidate failed verification (see REFUSED above)."
  exit 1
fi
if cmp -s "$LOCK" "$NEW_LOCK"; then
  say "Nothing to update."
  exit 0
fi
diff -u "$LOCK" "$NEW_LOCK" | sed "1,2s|$WORK/lock.sh|$LOCK (candidate)|" || true
bash -n "$NEW_LOCK" || die "the candidate lock does not parse"
if (( ! WRITE )); then
  say ""
  say "Dry run: nothing written. Rerun with --write to apply, then follow docs/development.md (\"Updating pinned artifacts\")."
  exit 0
fi
cp "$NEW_LOCK" "$LOCK.update-locks.tmp"
mv -f "$LOCK.update-locks.tmp" "$LOCK"
say ""
say "Wrote $LOCK. Next: LEOS_ARTIFACT_ALL_PLATFORMS=1 bash tests/locked-artifacts-test.sh, bash tests/locked-plugins-test.sh, and the provisioning workflow."
