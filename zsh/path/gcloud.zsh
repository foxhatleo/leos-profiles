# Google Cloud SDK via Homebrew
if __leos_gc_prefix=$(__leos_brew_prefix) && [[ -d $__leos_gc_prefix/share/google-cloud-sdk ]]; then
  source "$__leos_gc_prefix/share/google-cloud-sdk/path.zsh.inc"
  [[ -f $__leos_gc_prefix/share/google-cloud-sdk/completion.zsh.inc ]] && \
    source "$__leos_gc_prefix/share/google-cloud-sdk/completion.zsh.inc"
fi
