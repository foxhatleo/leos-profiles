#!/usr/bin/env bash
# shellcheck disable=SC2034
# Pinned, executable third-party sources used by install.sh.
#
# Update a value only as part of a reviewed dependency update; tools/update-locks.sh
# proposes one from upstream release metadata and checks it against upstream
# integrity data (docs/development.md, "Updating pinned artifacts"). Every Git
# source is checked out at the exact commit below. Every other download is
# verified by SHA-256 before it is used: directly by the digest here, or, for a
# Nerd Font archive, by the release's SHA-256.txt, whose own digest is pinned.
#
# Not locked here: OS and Homebrew packages, the Node runtimes fnm installs, and
# the AI CLIs' own updaters. Those follow their channels (see README).

readonly PYENV_REPOSITORY="https://github.com/pyenv/pyenv.git"
readonly PYENV_COMMIT="e4c462dc70951c8714d069522448c9583a38c913"
readonly RBENV_REPOSITORY="https://github.com/rbenv/rbenv.git"
readonly RBENV_COMMIT="7f984a7bb5c084b0c1c532441862eed5bbeab129"
readonly RUBY_BUILD_REPOSITORY="https://github.com/rbenv/ruby-build.git"
readonly RUBY_BUILD_COMMIT="9207ff8331f18149b6ae071089d4ea73af304a75"

readonly ZSH_AUTOSUGGESTIONS_REPOSITORY="https://github.com/zsh-users/zsh-autosuggestions.git"
readonly ZSH_AUTOSUGGESTIONS_COMMIT="85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5"
readonly ZSH_SYNTAX_HIGHLIGHTING_REPOSITORY="https://github.com/zsh-users/zsh-syntax-highlighting.git"
readonly ZSH_SYNTAX_HIGHLIGHTING_COMMIT="1d85c692615a25fe2293bdd44b34c217d5d2bf04"
readonly ZSH_COMPLETIONS_REPOSITORY="https://github.com/zsh-users/zsh-completions.git"
readonly ZSH_COMPLETIONS_COMMIT="f63d0e642261e40dfaadfcef478ef338e1aa315f"
readonly FZF_TAB_REPOSITORY="https://github.com/Aloxaf/fzf-tab.git"
readonly FZF_TAB_COMMIT="24105b15714bfec37989ed5c5b6e60f572253019"

# Nerd Fonts: one font's release archive, <Font>.tar.xz, from this release.
# Its digest is read from the release's SHA-256.txt, whose own digest is
# pinned here (GitHub's release-asset SHA-256 for that file), so the list is
# verified before it vouches for an archive or a font name (ONB-9).
readonly NERD_FONTS_VERSION="v3.5.1"
readonly NERD_FONTS_RELEASE_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1"
readonly NERD_FONTS_CHECKSUMS_SHA256="e03d7ad54547d83f1620719cbc89b5684bc0c6fb028160640aa322b5035a63fb"

readonly HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/feb6351d0d1a766a281d9691d4269cb026ff8f70/install.sh"
readonly HOMEBREW_INSTALL_SHA256="99287f194a8b3c9e6b0203a11a5fa54518be57209343e6bb954dec4635796d9d"

# rpatool has no release tags. Its author's archived GitHub repository provides
# an immutable copy of the final pre-Codeberg commit; the content is also
# SHA-256 verified before installation.
readonly RPATOOL_URL="https://raw.githubusercontent.com/Shizmob/rpatool/74f26d5dfdd645483e02552aa766ca447ad6b191/rpatool"
readonly RPATOOL_SHA256="d343124cebd832f712540cc6468253f7e303979467e11c7490807f42c13963f1"

readonly BUN_VERSION="1.3.11"
readonly BUN_DARWIN_AARCH64_URL="https://github.com/oven-sh/bun/releases/download/bun-v1.3.11/bun-darwin-aarch64.zip"
readonly BUN_DARWIN_AARCH64_SHA256="6f5a3467ed9caec4795bf78cd476507d9f870c7d57b86c945fcb338126772ffc"
readonly BUN_DARWIN_X64_URL="https://github.com/oven-sh/bun/releases/download/bun-v1.3.11/bun-darwin-x64.zip"
readonly BUN_DARWIN_X64_SHA256="c4fe2b9247218b0295f24e895aaec8fee62e74452679a9026b67eacbd611a286"
readonly BUN_LINUX_AARCH64_URL="https://github.com/oven-sh/bun/releases/download/bun-v1.3.11/bun-linux-aarch64.zip"
readonly BUN_LINUX_AARCH64_SHA256="d13944da12a53ecc74bf6a720bd1d04c4555c038dfe422365356a7be47691fdf"
readonly BUN_LINUX_X64_URL="https://github.com/oven-sh/bun/releases/download/bun-v1.3.11/bun-linux-x64.zip"
readonly BUN_LINUX_X64_SHA256="8611ba935af886f05a6f38740a15160326c15e5d5d07adef966130b4493607ed"

readonly FNM_VERSION="1.39.0"
readonly FNM_DARWIN_URL="https://github.com/Schniz/fnm/releases/download/v1.39.0/fnm-macos.zip"
readonly FNM_DARWIN_SHA256="f046483e85c53b3278efe49a3620c8680f22efa58a8dabfd03eafc6b59b31a25"
readonly FNM_LINUX_X64_URL="https://github.com/Schniz/fnm/releases/download/v1.39.0/fnm-linux.zip"
readonly FNM_LINUX_X64_SHA256="7807664f39d39fc518da1c35ba0181e4b3267603c4b1dedeb4b5fc6ae440a224"
readonly FNM_LINUX_AARCH64_URL="https://github.com/Schniz/fnm/releases/download/v1.39.0/fnm-arm64.zip"
readonly FNM_LINUX_AARCH64_SHA256="4eaff58b2c5bf30d0934027572dd0b5bbb60d2a1af309230b53662d4b1d45599"

readonly YARN_VERSION="1.22.22"
readonly YARN_URL="https://registry.npmjs.org/yarn/-/yarn-1.22.22.tgz"
readonly YARN_SHA256="c17d3797fb9a9115bf375e31bfd30058cac6bc9c3b8807a3d8cb2094794b51ca"
# Engine ranges copied from the pinned package manifests; artifact CI verifies them.
readonly YARN_NODE_ENGINE=">=4.0.0"
readonly PNPM_NODE_ENGINE=">=22.13"
readonly PNPM_VERSION="11.11.0"
readonly PNPM_URL="https://registry.npmjs.org/pnpm/-/pnpm-11.11.0.tgz"
readonly PNPM_SHA256="85ef2eff216a1ae90804c00c8dfbfa6685353644650d10906a893c05aedcd884"

# uv ships uv and uvx in one archive. Linux uses the musl builds, as Starship
# does: they are statically linked, so one binary runs on every supported
# distribution with no glibc-version floor. uv still detects the host's libc
# at run time, so the Pythons it downloads match the host. macOS is
# Apple-silicon only (Intel Macs are unsupported). Digests are GitHub's
# release-asset SHA-256 values, checked against uv's own .sha256 files.
readonly UV_VERSION="0.13.0"
readonly UV_DARWIN_AARCH64_URL="https://github.com/astral-sh/uv/releases/download/0.13.0/uv-aarch64-apple-darwin.tar.gz"
readonly UV_DARWIN_AARCH64_SHA256="a9c1b29002cf3c83f07fa9cd8a887a3be0107d90e23189721221e7257db8e3d6"
readonly UV_LINUX_AARCH64_URL="https://github.com/astral-sh/uv/releases/download/0.13.0/uv-aarch64-unknown-linux-musl.tar.gz"
readonly UV_LINUX_AARCH64_SHA256="281ca6cf43f4e26e35474839ad4861be86de42af2682f74134460f5b2071b96d"
readonly UV_LINUX_X64_URL="https://github.com/astral-sh/uv/releases/download/0.13.0/uv-x86_64-unknown-linux-musl.tar.gz"
readonly UV_LINUX_X64_SHA256="b0828fc4cdc47d65951e94b5f0a15a5364420e8dcd88723f3b21e7a2eb30bbc3"

# Linux uses Starship's statically linked musl builds on both CPUs, as its
# own installer does (BP-11); digests are GitHub's release-asset values.
readonly STARSHIP_VERSION="1.26.0"
readonly STARSHIP_DARWIN_AARCH64_URL="https://github.com/starship/starship/releases/download/v1.26.0/starship-aarch64-apple-darwin.tar.gz"
readonly STARSHIP_DARWIN_AARCH64_SHA256="c40b27b11f580411e068f2fa6c1be7830a387c0bc47a94d1d37f32b054c5361d"
readonly STARSHIP_DARWIN_X64_URL="https://github.com/starship/starship/releases/download/v1.26.0/starship-x86_64-apple-darwin.tar.gz"
readonly STARSHIP_DARWIN_X64_SHA256="5548f406a4b6f5695903bdea83f77ce47ec12c8c0e62dabd33122d8f133e4207"
readonly STARSHIP_LINUX_AARCH64_URL="https://github.com/starship/starship/releases/download/v1.26.0/starship-aarch64-unknown-linux-musl.tar.gz"
readonly STARSHIP_LINUX_AARCH64_SHA256="dc30189378d2f2e287384e8a692d3f95ad1df64cf0e8c36aa9201516028aed6b"
readonly STARSHIP_LINUX_X64_URL="https://github.com/starship/starship/releases/download/v1.26.0/starship-x86_64-unknown-linux-musl.tar.gz"
readonly STARSHIP_LINUX_X64_SHA256="b7c232b0e8249d8e55a40beb79c5c43a7d370f3f9408bd215deb0170daeaadf3"
