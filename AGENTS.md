# Personal dotfiles

This repo owns selected user configuration deployed to /home/pontual.
Edit the task worktree first. Applying to the live home is a separate explicit
action; do not deploy merely because a config edit was requested.
Use the Omarchy skill for desktop customization. /usr/share/omarchy is the
installed package and must not be edited. Omarchy source development requires
a separate checkout. Preserve credential environment lookups; never capture
credentials, application state, herdr sessions, caches, or backup files.

Run scripts/dotfiles.py plan to review deployment and scripts/dotfiles.py apply
only when live deployment is requested. Apply backs up replaced files and does
not delete unrelated live files. Deleting a tracked file does not remove its
live copy; document any required removal separately.
