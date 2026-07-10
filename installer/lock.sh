#!/usr/bin/env bash
# shellcheck disable=SC2034
# Pinned, executable third-party sources used by install.sh.
#
# Update a value only as part of a reviewed dependency update.  Every Git
# source is checked out at the exact commit below; the Homebrew installer and
# rpatool download are additionally verified by SHA-256 before execution.

readonly LEOS_PROFILE_REPOSITORY="https://github.com/foxhatleo/leos-profiles.git"

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
readonly NERD_FONTS_REPOSITORY="https://github.com/ryanoasis/nerd-fonts.git"
readonly NERD_FONTS_COMMIT="4f133076f3c1ec224745850bdf433d4368bca07e"

readonly HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/feb6351d0d1a766a281d9691d4269cb026ff8f70/install.sh"
readonly HOMEBREW_INSTALL_SHA256="99287f194a8b3c9e6b0203a11a5fa54518be57209343e6bb954dec4635796d9d"

# Codeberg currently does not offer a stable release artifact for rpatool. The
# content digest intentionally makes a changed upstream branch fail closed
# until this lock is reviewed and updated.
readonly RPATOOL_URL="https://codeberg.org/shiz/rpatool/raw/branch/master/rpatool"
readonly RPATOOL_SHA256="92bfad99b733ce0d70b59b85acfaf0977b3a982711f50c20c56a065db9291c39"

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
readonly FNM_MACOS_URL="https://github.com/Schniz/fnm/releases/download/v1.39.0/fnm-macos.zip"
readonly FNM_MACOS_SHA256="f046483e85c53b3278efe49a3620c8680f22efa58a8dabfd03eafc6b59b31a25"
readonly FNM_LINUX_X64_URL="https://github.com/Schniz/fnm/releases/download/v1.39.0/fnm-linux.zip"
readonly FNM_LINUX_X64_SHA256="7807664f39d39fc518da1c35ba0181e4b3267603c4b1dedeb4b5fc6ae440a224"
readonly FNM_LINUX_AARCH64_URL="https://github.com/Schniz/fnm/releases/download/v1.39.0/fnm-arm64.zip"
readonly FNM_LINUX_AARCH64_SHA256="4eaff58b2c5bf30d0934027572dd0b5bbb60d2a1af309230b53662d4b1d45599"

readonly STARSHIP_VERSION="1.26.0"
readonly STARSHIP_DARWIN_AARCH64_URL="https://github.com/starship/starship/releases/download/v1.26.0/starship-aarch64-apple-darwin.tar.gz"
readonly STARSHIP_DARWIN_AARCH64_SHA256="c40b27b11f580411e068f2fa6c1be7830a387c0bc47a94d1d37f32b054c5361d"
readonly STARSHIP_DARWIN_X64_URL="https://github.com/starship/starship/releases/download/v1.26.0/starship-x86_64-apple-darwin.tar.gz"
readonly STARSHIP_DARWIN_X64_SHA256="5548f406a4b6f5695903bdea83f77ce47ec12c8c0e62dabd33122d8f133e4207"
readonly STARSHIP_LINUX_AARCH64_URL="https://github.com/starship/starship/releases/download/v1.26.0/starship-aarch64-unknown-linux-musl.tar.gz"
readonly STARSHIP_LINUX_AARCH64_SHA256="dc30189378d2f2e287384e8a692d3f95ad1df64cf0e8c36aa9201516028aed6b"
readonly STARSHIP_LINUX_X64_URL="https://github.com/starship/starship/releases/download/v1.26.0/starship-x86_64-unknown-linux-gnu.tar.gz"
readonly STARSHIP_LINUX_X64_SHA256="321f0dd7af8340a5f2e6a8fec6538a04f617486f9ec70d878f91c09cd8deef22"
