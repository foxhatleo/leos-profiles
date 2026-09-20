# Google Cloud SDK via Homebrew — PATH only.
#
# completion.zsh.inc is deliberately NOT sourced here: it runs its own compinit
# when `compdef` is undefined, which during this PATH phase would build
# ~/.zcompdump from an fpath that does not yet include zsh-completions, and
# interactive.zsh's <24h `compinit -C` fast path would then trust that truncated
# dump. It lives in path/gcloud-completion.zsh, loaded after compinit instead.
if __leos_gc_prefix=${HOMEBREW_PREFIX:-$(__leos_brew_prefix)} && [[ -d $__leos_gc_prefix/share/google-cloud-sdk ]]; then
  source "$__leos_gc_prefix/share/google-cloud-sdk/path.zsh.inc"
fi

unset __leos_gc_prefix

:
