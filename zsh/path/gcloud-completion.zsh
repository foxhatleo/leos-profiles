# Google Cloud SDK completions — loaded from interactive.zsh, AFTER compinit.
#
# Google's completion.zsh.inc guards its own `compinit` on `compdef` being
# undefined, so sourcing it here (rather than during the PATH phase alongside
# path.zsh.inc) makes it skip that entirely: no second compinit, no dump built
# from an incomplete fpath, and no bypassing the compaudit handling that
# interactive.zsh does deliberately.
#
# The prefix is re-derived rather than carried over from path/gcloud.zsh, which
# is free: path/brew.zsh has already exported HOMEBREW_PREFIX by now.
if __leos_gc_prefix=${HOMEBREW_PREFIX:-$(__leos_brew_prefix)} &&
   [[ -f $__leos_gc_prefix/share/google-cloud-sdk/completion.zsh.inc ]]; then
  source "$__leos_gc_prefix/share/google-cloud-sdk/completion.zsh.inc"
fi

unset __leos_gc_prefix

:
