#!/usr/bin/env python3
"""Compatibility entry point for the canonical env/ Bash deployment tool."""
import subprocess
import sys
from pathlib import Path

if len(sys.argv) < 2:
    raise SystemExit("Usage: scripts/dotfiles.py {plan|diff|apply|capture|backup|restore|prune|sync} ...")
tool = Path(__file__).resolve().with_name("envctl")
args = sys.argv[1:]
env = None
if "--home" in args:
    index = args.index("--home")
    if index + 1 >= len(args):
        raise SystemExit("--home requires a path")
    import os
    env = os.environ.copy()
    env["DOTFILES_HOME"] = args[index + 1]
    del args[index:index + 2]
raise SystemExit(subprocess.call([str(tool), *args], env=env))
