#!/usr/bin/env bash
# shellcheck disable=SC2034
# Where install.sh gets its third-party tools.
#
# Nothing here names a version. Tools follow upstream, held back by a minimum
# release age (--min-release-age, default 7 days; saved as `release-age`), so
# a compromised or broken release has a week to be noticed and pulled before
# it reaches a workstation:
#   - On Linux, release tools come from the newest GitHub release (not a draft
#     or prerelease) published at least that long ago, checked against the
#     SHA-256 digest GitHub publishes for the asset and, when gh is logged in
#     and the project publishes one, its GitHub attestation.
#   - On macOS, Homebrew installs them (the registry's formula column) at
#     Homebrew's current version; Homebrew has no release-age gate.
#   - Git checkouts end detached at a release, chosen per source by
#     <PREFIX>_FOLLOW:
#       tag      the newest stable tag (v1.2.3, 1.2) created at least that
#                long ago;
#       commit   the newest commit on the default branch at least that old,
#                for projects whose tags lag years behind their branch;
#       tag-now  the newest stable tag with no delay.
# A full upgrade (apply's default, reconcile --full-upgrade) moves all of them
# forward; otherwise a run only repairs what is missing.

readonly RBENV_REPOSITORY="https://github.com/rbenv/rbenv.git"
readonly RUBY_BUILD_REPOSITORY="https://github.com/rbenv/ruby-build.git"
# rbenv releases often enough for tags. ruby-build is mostly Ruby build
# definitions: a new tag is how a Ruby security release becomes installable,
# so it is not held back. A new Ruby minor line still waits the minimum
# release age (resolve_ruby_version), measured from the commit that added its
# x.y.0 definition.
readonly RBENV_FOLLOW=tag
readonly RUBY_BUILD_FOLLOW=tag-now

# Runtimes. Node: the LTS line fnm installs comes from the release index
# (node_dist_index_url). Python: uv's CPython builds; a new minor line waits
# the minimum release age, counted from python.org's x.y.0 release date read
# from this API (`?name=Python%203.14.0` returns a one-element JSON list).
readonly PYTHON_RELEASE_API="https://www.python.org/api/v2/downloads/release/"

readonly ZSH_AUTOSUGGESTIONS_REPOSITORY="https://github.com/zsh-users/zsh-autosuggestions.git"
readonly ZSH_SYNTAX_HIGHLIGHTING_REPOSITORY="https://github.com/zsh-users/zsh-syntax-highlighting.git"
readonly ZSH_COMPLETIONS_REPOSITORY="https://github.com/zsh-users/zsh-completions.git"
readonly FZF_TAB_REPOSITORY="https://github.com/Aloxaf/fzf-tab.git"
# zsh-autosuggestions (last tag 2024) and zsh-syntax-highlighting (last tag
# 2023) fix bugs on their default branch for years between tags, so they
# follow commits; zsh-completions and fzf-tab tag their releases.
readonly ZSH_AUTOSUGGESTIONS_FOLLOW=commit
readonly ZSH_SYNTAX_HIGHLIGHTING_FOLLOW=commit
readonly ZSH_COMPLETIONS_FOLLOW=tag
readonly FZF_TAB_FOLLOW=tag

# Nerd Fonts: one font's archive, <Font>.tar.xz, from the newest release at
# least the minimum release age old, checked against that release's
# SHA-256.txt. A run picks the release once (nerd_fonts_release) and downloads
# both files from NERD_FONTS_DOWNLOAD_URL/<tag>, so a release published
# mid-run cannot pair one release's checksums with another's archive.
# NERD_FONTS_SIGNATURE_URL is the font step's signature text, kept from the
# installs that followed the latest release so they do not re-run.
readonly NERD_FONTS_REPOSITORY="ryanoasis/nerd-fonts"
readonly NERD_FONTS_DOWNLOAD_URL="https://github.com/ryanoasis/nerd-fonts/releases/download"
readonly NERD_FONTS_SIGNATURE_URL="https://github.com/ryanoasis/nerd-fonts/releases/latest/download"

# Two sources stay pinned to reviewed copies rather than following upstream.
# Homebrew's installer runs once, as the first thing on a new Mac, so it is
# checked against a reviewed copy rather than whatever HEAD serves that day.
# This commit (2026-11-06) supports macOS 15 through 27 (its
# MACOS_NEWEST_UNSUPPORTED is 28.0) and Apple silicon only.
readonly HOMEBREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/7986efac25016e41eed7e471666140c06f9d97cf/install.sh"
readonly HOMEBREW_INSTALL_SHA256="5f333bbe53bc490e51e7ccb1df8779b3dd6ee73a1a7379efda216edb08ccb148"
# rpatool has no releases. Its GitHub repository is archived and development
# moved to codeberg.org/shiz/rpatool; this is the final GitHub commit, which
# Codeberg also carries (its one later commit, 2026-01, repackages the tool).
readonly RPATOOL_URL="https://raw.githubusercontent.com/Shizmob/rpatool/74f26d5dfdd645483e02552aa766ca447ad6b191/rpatool"
readonly RPATOOL_SHA256="d343124cebd832f712540cc6468253f7e303979467e11c7490807f42c13963f1"

# Linux release assets, per CPU: <PREFIX>_REPOSITORY is the GitHub project and
# <PREFIX>_LINUX_<AARCH64|X64>_ASSET the file in its picked release. Starship
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
