#!/usr/bin/env bash
# tools/update-locks.sh against fake upstreams: gh and curl are PATH stubs that
# serve fixture files, so nothing here touches the network or the real lock.
# Covers a verified dry run, --write, and refusals (a GitHub digest, a .sha256
# file, a bun signature, npm integrity, a non-fast-forward commit, an unsafe
# tag) that leave the lock untouched.
# shellcheck disable=SC2016

set -Eeuo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
for tool in jq openssl; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP: update-locks test needs %s\n' "$tool"; exit 0; }
done
if command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  sha256() { sha256sum "$1" | awk '{print $1}'; }
fi

FIXTURE=$(mktemp -d)
cleanup() {
  [[ -z ${GNUPGHOME:-} ]] || gpgconf --homedir "$GNUPGHOME" --kill all >/dev/null 2>&1 || true
  rm -rf "$FIXTURE"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; [[ ! -f $FIXTURE/out ]] || cat "$FIXTURE/out" >&2; exit 1; }

STUBS=$FIXTURE/bin GH=$FIXTURE/gh WEB=$FIXTURE/web
mkdir -p "$STUBS" "$GH" "$WEB"
# Fixture names: every character outside [A-Za-z0-9._-] becomes "_".
key() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g'; }
cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
[[ $1 == api ]] || exit 2
file=$GH_FIXTURES/$(printf '%s' "$2" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g')
[[ -f $file ]] || { printf 'gh stub: no fixture for %s\n' "$2" >&2; exit 1; }
cat "$file"
STUB
cat > "$STUBS/curl" <<'STUB'
#!/usr/bin/env bash
out= url=
while (( $# )); do
  case $1 in
    --output|-o) out=$2; shift ;;
    https://*) url=$1 ;;
  esac
  shift
done
printf '%s\n' "$url" >> "$CURL_LOG"
file=$WEB_FIXTURES/$(printf '%s' "$url" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g')
[[ -f $file ]] || { printf 'curl: (22) 404 %s\n' "$url" >&2; exit 22; }
cp "$file" "$out"
STUB
chmod +x "$STUBS/gh" "$STUBS/curl"
export GH_FIXTURES=$GH WEB_FIXTURES=$WEB CURL_LOG=$FIXTURE/curl-log
export PATH="$STUBS:$PATH"

# serve <url> <file>: what the fake web returns for url.
serve() { cp "$2" "$WEB/$(key "$1")"; }
# api <path> <json>
api() { printf '%s\n' "$2" > "$GH/$(key "$1")"; }

# --- the lock under test -------------------------------------------------------
OLD_SHA=0000000000000000000000000000000000000000000000000000000000000000
OLD_COMMIT=1111111111111111111111111111111111111111
NEW_COMMIT=2222222222222222222222222222222222222222
cat > "$FIXTURE/lock.sh" <<LOCK
#!/usr/bin/env bash
readonly STARSHIP_VERSION="1.0.0"
readonly STARSHIP_LINUX_X64_URL="https://github.com/starship/starship/releases/download/v1.0.0/starship-x86_64-unknown-linux-musl.tar.gz"
readonly STARSHIP_LINUX_X64_SHA256="$OLD_SHA"
readonly PNPM_NODE_ENGINE=">=18.12"
readonly PNPM_VERSION="9.0.0"
readonly PNPM_URL="https://registry.npmjs.org/pnpm/-/pnpm-9.0.0.tgz"
readonly PNPM_SHA256="$OLD_SHA"
readonly FZF_TAB_REPOSITORY="https://github.com/Aloxaf/fzf-tab.git"
readonly FZF_TAB_COMMIT="$OLD_COMMIT"
LOCK
cp "$FIXTURE/lock.sh" "$FIXTURE/lock.orig"

# --- starship: release assets with .sha256 files and GitHub digests ------------
asset=starship-x86_64-unknown-linux-musl.tar.gz
base=https://github.com/starship/starship/releases/download/v1.1.0
printf 'starship 1.1.0\n' > "$FIXTURE/$asset"
STARSHIP_SHA=$(sha256 "$FIXTURE/$asset")
printf '%s\n' "$STARSHIP_SHA" > "$FIXTURE/$asset.sha256"
serve "$base/$asset" "$FIXTURE/$asset"
serve "$base/$asset.sha256" "$FIXTURE/$asset.sha256"
starship_release() {
  jq -n --arg base "$base" --arg asset "$asset" --arg digest "$1" '{tag_name: "v1.1.0", assets: [
    {name: $asset, digest: ("sha256:" + $digest), browser_download_url: ($base + "/" + $asset)},
    {name: ($asset + ".sha256"), digest: null, browser_download_url: ($base + "/" + $asset + ".sha256")}]}'
}
api repos/starship/starship/releases/latest "$(starship_release "$STARSHIP_SHA")"

# --- pnpm: tarball, dist.integrity and an ECDSA registry signature -------------
mkdir -p "$FIXTURE/pkg/package"
printf '{"name":"pnpm","version":"9.1.0","engines":{"node":">=18.12"},"scripts":{"postinstall":"node x.js"}}\n' \
  > "$FIXTURE/pkg/package/package.json"
tar -czf "$FIXTURE/pnpm.tgz" -C "$FIXTURE/pkg" package
PNPM_SHA=$(sha256 "$FIXTURE/pnpm.tgz")
INTEGRITY=sha512-$(openssl dgst -sha512 -binary "$FIXTURE/pnpm.tgz" | openssl base64 -A)
openssl ecparam -name prime256v1 -genkey -noout -out "$FIXTURE/npm-key.pem" 2>/dev/null
NPM_PUB=$(openssl ec -in "$FIXTURE/npm-key.pem" -pubout -outform DER 2>/dev/null | openssl base64 -A)
npm_sig() { printf '%s' "$1" | openssl dgst -sha256 -sign "$FIXTURE/npm-key.pem" | openssl base64 -A; }
GOOD_SIG=$(npm_sig "pnpm@9.1.0:$INTEGRITY")
pnpm_meta() {
  jq -n --arg integrity "$1" --arg sig "$2" '{name: "pnpm", version: "9.1.0",
    engines: {node: ">=18.12"},
    dist: {tarball: "https://registry.npmjs.org/pnpm/-/pnpm-9.1.0.tgz", integrity: $integrity,
           signatures: [{keyid: "SHA256:test", sig: $sig}]}}' > "$FIXTURE/pnpm-latest.json"
  serve https://registry.npmjs.org/pnpm/latest "$FIXTURE/pnpm-latest.json"
}
pnpm_meta "$INTEGRITY" "$GOOD_SIG"
jq -n --arg key "$NPM_PUB" '{keys: [{keyid: "SHA256:test", key: $key, expires: null}]}' > "$FIXTURE/keys.json"
serve https://registry.npmjs.org/-/npm/v1/keys "$FIXTURE/keys.json"
serve https://registry.npmjs.org/pnpm/-/pnpm-9.1.0.tgz "$FIXTURE/pnpm.tgz"

# --- fzf-tab: a pinned commit, fast-forward only -------------------------------
api repos/Aloxaf/fzf-tab/commits/HEAD "{\"sha\": \"$NEW_COMMIT\", \"commit\": {\"verification\": {\"verified\": true}}}"
api "repos/Aloxaf/fzf-tab/compare/$OLD_COMMIT...$NEW_COMMIT" '{"status": "ahead"}'

run() {
  local status=0
  "$BASH" "$ROOT/tools/update-locks.sh" --lock "$FIXTURE/lock.sh" "$@" > "$FIXTURE/out" 2>&1 || status=$?
  return "$status"
}
unchanged() { cmp -s "$FIXTURE/lock.sh" "$FIXTURE/lock.orig" || fail "$1: the lock changed"; }
expect_refusal() {
  local label=$1 status=0
  shift
  run "$@" || status=$?
  [[ $status == 1 ]] || fail "$label: exit $status, expected 1"
  grep -q 'REFUSED' "$FIXTURE/out" || fail "$label: no REFUSED line"
  unchanged "$label"
}

# 1. A verified dry run prints the plan and the diff and writes nothing.
run || fail 'dry run'
unchanged 'dry run'
grep -q '^starship: 1.0.0 -> 1.1.0' "$FIXTURE/out" || fail 'dry run: starship plan'
grep -q "ok: $asset matches $asset.sha256" "$FIXTURE/out" || fail 'dry run: .sha256 check'
grep -q 'ok: tarball matches dist.integrity' "$FIXTURE/out" || fail 'dry run: npm integrity'
grep -q 'ok: registry signature by SHA256:test' "$FIXTURE/out" || fail 'dry run: npm signature'
grep -q 'declares postinstall; the installer skips them' "$FIXTURE/out" || fail 'dry run: lifecycle note'
grep -q "^+readonly FZF_TAB_COMMIT=\"$NEW_COMMIT\"" "$FIXTURE/out" || fail 'dry run: diff'
grep -q 'Dry run: nothing written' "$FIXTURE/out" || fail 'dry run: summary'

# 2. Refusals: each leaves the lock untouched, even with --write.
api repos/starship/starship/releases/latest "$(starship_release "$OLD_SHA")"
expect_refusal 'GitHub digest mismatch' --only starship --write
grep -q 'does not match GitHub' "$FIXTURE/out" || fail 'digest mismatch message'
api repos/starship/starship/releases/latest "$(starship_release "$STARSHIP_SHA")"

printf '%s\n' "$OLD_SHA" > "$FIXTURE/bad.sha256"
serve "$base/$asset.sha256" "$FIXTURE/bad.sha256"
expect_refusal '.sha256 mismatch' --write
serve "$base/$asset.sha256" "$FIXTURE/$asset.sha256"

pnpm_meta "sha512-AAAA" "$GOOD_SIG"
expect_refusal 'npm integrity mismatch' --only pnpm --write
pnpm_meta "$INTEGRITY" "$(npm_sig "pnpm@9.1.1:$INTEGRITY")"
expect_refusal 'npm signature over another version' --only pnpm --write
pnpm_meta "$INTEGRITY" "$GOOD_SIG"

api "repos/Aloxaf/fzf-tab/compare/$OLD_COMMIT...$NEW_COMMIT" '{"status": "diverged"}'
expect_refusal 'non-fast-forward commit' --only fzf-tab --write
api "repos/Aloxaf/fzf-tab/compare/$OLD_COMMIT...$NEW_COMMIT" '{"status": "ahead"}'

api repos/starship/starship/releases/latest '{"tag_name": "v1.1.0$(touch pwned)", "assets": []}'
expect_refusal 'unsafe tag name' --only starship --write
[[ ! -e pwned && ! -e $FIXTURE/pwned ]] || fail 'a tag name was executed'
api repos/starship/starship/releases/latest "$(starship_release "$STARSHIP_SHA")"

# A lock variable the tool does not cover is an error, not silently skipped.
printf 'readonly MYSTERY_URL="https://example.com/x"\n' >> "$FIXTURE/lock.sh"
status=0; run || status=$?
[[ $status == 2 ]] || fail "unknown lock variable: exit $status"
grep -q 'MYSTERY_URL' "$FIXTURE/out" || fail 'unknown lock variable: not named'
cp "$FIXTURE/lock.orig" "$FIXTURE/lock.sh"

# 3. bun: SHASUMS256.txt clear-signed by a pinned key (a fixture key here).
if command -v gpg >/dev/null 2>&1 && command -v gpgconf >/dev/null 2>&1; then
  export GNUPGHOME=$FIXTURE/gnupg
  mkdir -m 700 "$GNUPGHOME"
  if gpg --batch --passphrase '' --quick-gen-key 'Bun test <bun@example.invalid>' ed25519 sign never >/dev/null 2>&1; then
    FPR=$(gpg --batch --with-colons --fingerprint 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')
    gpg --batch --armor --export "$FPR" > "$FIXTURE/bun-key.asc"
    cat >> "$FIXTURE/lock.sh" <<LOCK
readonly BUN_VERSION="1.0.0"
readonly BUN_DARWIN_AARCH64_URL="https://github.com/oven-sh/bun/releases/download/bun-v1.0.0/bun-darwin-aarch64.zip"
readonly BUN_DARWIN_AARCH64_SHA256="$OLD_SHA"
LOCK
    cp "$FIXTURE/lock.sh" "$FIXTURE/lock.orig"
    bbase=https://github.com/oven-sh/bun/releases/download/bun-v1.1.0
    printf 'bun 1.1.0\n' > "$FIXTURE/bun-darwin-aarch64.zip"
    BUN_SHA=$(sha256 "$FIXTURE/bun-darwin-aarch64.zip")
    printf '%s  bun-darwin-aarch64.zip\n' "$BUN_SHA" > "$FIXTURE/SHASUMS256.txt"
    gpg --batch --yes --local-user "$FPR" --clearsign --output "$FIXTURE/SHASUMS256.txt.asc" "$FIXTURE/SHASUMS256.txt" 2>/dev/null
    serve "$bbase/bun-darwin-aarch64.zip" "$FIXTURE/bun-darwin-aarch64.zip"
    serve "$bbase/SHASUMS256.txt.asc" "$FIXTURE/SHASUMS256.txt.asc"
    api repos/oven-sh/bun/releases/latest "$(jq -n --arg base "$bbase" --arg digest "$BUN_SHA" '{tag_name: "bun-v1.1.0", assets: [
      {name: "bun-darwin-aarch64.zip", digest: ("sha256:" + $digest), browser_download_url: ($base + "/bun-darwin-aarch64.zip")},
      {name: "SHASUMS256.txt.asc", digest: null, browser_download_url: ($base + "/SHASUMS256.txt.asc")}]}')"
    export UPDATE_LOCKS_TEST_BUN_KEY_FILE=$FIXTURE/bun-key.asc UPDATE_LOCKS_TEST_BUN_FINGERPRINT=$FPR
    run --only bun || fail 'bun: signed sums'
    grep -q "ok: SHASUMS256.txt signed by $FPR" "$FIXTURE/out" || fail 'bun: signature line'
    grep -q 'ok: bun-darwin-aarch64.zip matches the signed SHASUMS256.txt' "$FIXTURE/out" || fail 'bun: sums line'
    # Tampered signed text no longer verifies.
    sed 's/^\([0-9a-f]\)/f/' "$FIXTURE/SHASUMS256.txt.asc" > "$FIXTURE/tampered.asc"
    serve "$bbase/SHASUMS256.txt.asc" "$FIXTURE/tampered.asc"
    expect_refusal 'bun: tampered SHASUMS256.txt.asc' --only bun --write
    serve "$bbase/SHASUMS256.txt.asc" "$FIXTURE/SHASUMS256.txt.asc"
    # The right signature but another key than the pinned fingerprint.
    UPDATE_LOCKS_TEST_BUN_FINGERPRINT=F3DCC08A8572C0749B3E18888EAB4D40A7B22B59 \
      expect_refusal 'bun: wrong pinned fingerprint' --only bun --write
    unset UPDATE_LOCKS_TEST_BUN_KEY_FILE UPDATE_LOCKS_TEST_BUN_FINGERPRINT
  else
    printf 'SKIP: bun signature cases (gpg cannot generate a key here)\n'
  fi
else
  printf 'SKIP: bun signature cases (no gpg)\n'
fi
[[ -z ${FPR:-} ]] || export UPDATE_LOCKS_TEST_BUN_KEY_FILE=$FIXTURE/bun-key.asc UPDATE_LOCKS_TEST_BUN_FINGERPRINT=$FPR

# 4. --write applies every verified candidate, and the result still parses.
run --write || fail 'write'
grep -q "^Wrote $FIXTURE/lock.sh" "$FIXTURE/out" || fail 'write: summary'
# shellcheck disable=SC1091
(
  source "$FIXTURE/lock.sh"
  [[ $STARSHIP_VERSION == 1.1.0 && $STARSHIP_LINUX_X64_SHA256 == "$STARSHIP_SHA" ]]
  [[ $STARSHIP_LINUX_X64_URL == "$base/$asset" ]]
  [[ $PNPM_VERSION == 9.1.0 && $PNPM_SHA256 == "$PNPM_SHA" && $PNPM_URL == https://registry.npmjs.org/pnpm/-/pnpm-9.1.0.tgz ]]
  [[ $FZF_TAB_COMMIT == "$NEW_COMMIT" ]]
  [[ -z ${BUN_VERSION:-} || $BUN_VERSION == 1.1.0 ]]
) || fail 'write: values'
# A second run finds nothing to do.
run --write || fail 'second run'
grep -q 'Nothing to update.' "$FIXTURE/out" || fail 'second run: not idempotent'

printf 'update-locks tests: PASS\n'
