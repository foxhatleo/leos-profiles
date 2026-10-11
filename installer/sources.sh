#!/usr/bin/env bash
# shellcheck disable=SC2034
# Where install.sh gets its third-party tools.
#
# Tools follow their upstream's latest release; nothing here names a version.
# On macOS, Homebrew installs them (the registry's formula column), so
# `brew upgrade` keeps them current. On Linux they are downloaded from the
# project's latest GitHub release and checked against the SHA-256 digest
# GitHub publishes for that asset. Git sources follow their default branch.
# A full upgrade (apply's default, reconcile --full-upgrade) moves all of them
# forward; otherwise a run only repairs what is missing.

readonly PYENV_REPOSITORY="https://github.com/pyenv/pyenv.git"
readonly RBENV_REPOSITORY="https://github.com/rbenv/rbenv.git"
readonly RUBY_BUILD_REPOSITORY="https://github.com/rbenv/ruby-build.git"

readonly ZSH_AUTOSUGGESTIONS_REPOSITORY="https://github.com/zsh-users/zsh-autosuggestions.git"
readonly ZSH_SYNTAX_HIGHLIGHTING_REPOSITORY="https://github.com/zsh-users/zsh-syntax-highlighting.git"
readonly ZSH_COMPLETIONS_REPOSITORY="https://github.com/zsh-users/zsh-completions.git"
readonly FZF_TAB_REPOSITORY="https://github.com/Aloxaf/fzf-tab.git"

# Nerd Fonts: one font's archive, <Font>.tar.xz, from the latest release,
# checked against that release's SHA-256.txt.
readonly NERD_FONTS_RELEASE_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download"

# Two sources stay pinned, because neither has anything newer to follow.
# Homebrew's installer runs once, as the first thing on a new Mac, so it is
# checked against a reviewed copy rather than whatever HEAD serves that day.
readonly HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/feb6351d0d1a766a281d9691d4269cb026ff8f70/install.sh"
readonly HOMEBREW_INSTALL_SHA256="99287f194a8b3c9e6b0203a11a5fa54518be57209343e6bb954dec4635796d9d"
# rpatool has no releases, and its GitHub repository is archived: this is its
# final commit there.
readonly RPATOOL_URL="https://raw.githubusercontent.com/Shizmob/rpatool/74f26d5dfdd645483e02552aa766ca447ad6b191/rpatool"
readonly RPATOOL_SHA256="d343124cebd832f712540cc6468253f7e303979467e11c7490807f42c13963f1"

# Linux release assets, per CPU: <PREFIX>_REPOSITORY is the GitHub project and
# <PREFIX>_LINUX_<AARCH64|X64>_ASSET the file in its latest release. Starship
# and uv use their statically linked musl builds, as their own installers do,
# so one binary runs on every supported distribution.
readonly BUN_REPOSITORY="oven-sh/bun"
readonly BUN_LINUX_AARCH64_ASSET="bun-linux-aarch64.zip"
readonly BUN_LINUX_X64_ASSET="bun-linux-x64.zip"

readonly FNM_REPOSITORY="Schniz/fnm"
readonly FNM_LINUX_AARCH64_ASSET="fnm-arm64.zip"
readonly FNM_LINUX_X64_ASSET="fnm-linux.zip"

readonly STARSHIP_REPOSITORY="starship/starship"
readonly STARSHIP_LINUX_AARCH64_ASSET="starship-aarch64-unknown-linux-musl.tar.gz"
readonly STARSHIP_LINUX_X64_ASSET="starship-x86_64-unknown-linux-musl.tar.gz"

readonly UV_REPOSITORY="astral-sh/uv"
readonly UV_LINUX_AARCH64_ASSET="uv-aarch64-unknown-linux-musl.tar.gz"
readonly UV_LINUX_X64_ASSET="uv-x86_64-unknown-linux-musl.tar.gz"
