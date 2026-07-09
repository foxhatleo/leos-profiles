#!/usr/bin/python3
# -*- coding: utf-8 -*-

import os
import sys
import re
import shutil

if len(sys.argv) <= 1:
    print("No argument provided.")
    exit(1)

IGNORED_DIRS = {'CloudStorage'}

def _term_width():
    # os.get_terminal_size raises OSError when stdout is not a tty (piped/CI runs).
    try:
        return os.get_terminal_size()[0]
    except OSError:
        return 80

def make_width(p):
    return p.ljust(_term_width(), ' ')

def smart_gen_progress(p, prompt='Scanning: {}...', newline=False) :
    p2 = re.sub('[^ a-zA-Z0-9!@#$%^&*()_+={}[\\]|\\\\:;"\'<>,.?\\/~`-]', '?', p)
    if p2.startswith(sys.argv[1]):
        p2 = p2[(len(sys.argv[1]) + 1):]
    empty = len(prompt) - 2
    max_allowed = _term_width() - empty
    sys.stdout.write(make_width(prompt.format(p2[:max_allowed])))
    if newline:
        sys.stdout.write('\n')
    else:
        sys.stdout.write('\r')
    sys.stdout.flush()

print("Running rmdsstore on \"{}\".".format(sys.argv[1]))
for root, dirs, files in os.walk(sys.argv[1], followlinks=False):
    dirs[:] = [d for d in dirs if not d.endswith('.duck') and d not in IGNORED_DIRS]
    smart_gen_progress(root)
    for name in dirs:
        if name == '$RECYCLE.BIN':
            smart_gen_progress(os.path.join(root, name), prompt='Removing {}...', newline=True)
            try:
                shutil.rmtree(os.path.join(root, name), ignore_errors=True)
            except OSError:
                smart_gen_progress(os.path.join(root, name), prompt='Could not remove {}.', newline=True)
    for name in files:
        if name == '.DS_Store' or name == 'Thumbs.db' or name == 'desktop.ini':
            smart_gen_progress(os.path.join(root, name), prompt='Removing {}...', newline=True)
            try:
                os.remove(os.path.join(root, name))
            except OSError:
                smart_gen_progress(os.path.join(root, name), prompt='Could not remove {}.', newline=True)

print("\nFinished.\n")
