#!/usr/bin/env python3
"""Review or deploy tracked configuration from this checkout."""
import argparse
from datetime import datetime, timezone
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['plan', 'apply'])
parser.add_argument('--home', type=Path, default=Path.home())
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
home = args.home.expanduser().resolve()
tracked = subprocess.check_output(['git', '-C', str(repo), 'ls-files', '-z'])
stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
backup = home / '.local/state/dotfiles/backups' / stamp
count = 0
for name in tracked.decode().split('\0'):
    if not (name.startswith('.config/') or name == '.zshrc'):
        continue
    source, target = repo / name, home / name
    if not source.is_file() and not source.is_symlink():
        continue
    if source.is_symlink():
        raise SystemExit(f'Review symlink manually before deployment: {name}')
    # Do not write through symlinked runtime files or directories.
    if any(p.is_symlink() for p in [target, *target.parents] if p != home):
        raise SystemExit(f'Review live symlink before deployment: {target}')
    if target.is_file() and source.read_bytes() == target.read_bytes() and (source.stat().st_mode & 0o777) == (target.stat().st_mode & 0o777):
        continue
    if target.exists() and not target.is_file():
        raise SystemExit(f'Expected a regular file: {target}')
    print(f'{"replace" if target.exists() else "create"}: {name}')
    count += 1
    if args.action == 'apply':
        if target.exists():
            saved = backup / name
            saved.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, saved)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
print(f'{count} file(s) {"deployed" if args.action == "apply" else "would change"}')
if args.action == 'apply' and backup.exists():
    print(f'Backups: {backup}')
