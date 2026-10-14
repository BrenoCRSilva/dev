#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$tmp"' EXIT
root="$tmp/repo"
home="$tmp/home"
state="$tmp/state"
mkdir -p "$root/scripts" "$root/env/.config/app" "$root/env/.config/nvim/lua" "$home"
mkdir -p "$root/env/.config/app/node_modules/pkg" "$root/env/.config/app/lua"
cp "$repo/scripts/envctl" "$root/scripts/envctl"
cat > "$root/env/dotfiles.manifest" <<'EOF'
.config/app
.config/nvim
!.config/app/ignored
EOF
printf 'one\n' > "$root/env/.config/app/main.conf"
printf 'ignored\n' > "$root/env/.config/app/node_modules/pkg/index.js"
printf 'generated\n' > "$root/env/.config/nvim/lua/fixture-palette.lua"
printf 'target\n' > "$root/env/.config/app/real.conf"
ln -s real.conf "$root/env/.config/app/link.conf"
run() { DOTFILES_ROOT="$root" DOTFILES_HOME="$home" DOTFILES_STATE_DIR="$state" "$root/scripts/envctl" "$@"; }

# The default state location is outside the checkout, and snapshots have
# private directory and metadata modes.
default_home="$tmp/default-home"
default_xdg="$tmp/default-xdg"
mkdir -p "$default_home"
XDG_STATE_HOME="$default_xdg" DOTFILES_HOME="$default_home" "$root/scripts/envctl" apply > "$tmp/default-state.out"
default_backup="$(sed -n 's/^Backups: //p' "$tmp/default-state.out")"
[[ "$default_backup" == "$default_xdg/dotfiles/backups/default/"* ]]

# Apply previews, creates files and safe relative symlinks, excludes bulk/generated
# material, and treats no-op apply/capture as successful without empty backups.
plan="$(run plan apply)"
[[ "$plan" == *"3 path(s) differ"* ]]
run apply > "$tmp/apply.out"
[[ "$(cat "$home/.config/app/main.conf")" == one ]]
[[ -L "$home/.config/app/link.conf" ]]
[[ ! -e "$home/.config/app/node_modules/pkg/index.js" ]]
[[ ! -e "$home/.config/nvim/lua/fixture-palette.lua" ]]
apply_backup="$(sed -n 's/^Backups: //p' "$tmp/apply.out")"
[[ "$(stat -c %a "$apply_backup")" == 700 ]]
[[ "$(stat -c %a "$(dirname "$(dirname "$apply_backup")")")" == 700 ]]
[[ "$(stat -c %a "$apply_backup/metadata")" == 600 ]]
[[ "$(sed -n 's/^complete=//p' "$apply_backup/metadata")" == yes ]]
[[ "$(run apply)" == *"0 path(s) applied"* ]]
[[ "$(run capture)" == *"0 path(s) captured"* ]]

# External Omarchy theme collection links are discoverable runtime data, not
# authored mirror content. The top-level link and files globbed beneath it are
# excluded, while authored theme files remain eligible for apply/capture.
mkdir -p "$root/env/.config/omarchy/themes/authored" "$home/.config/omarchy/themes" "$tmp/external/collection"
printf 'authored palette\n' > "$root/env/.config/omarchy/themes/authored/colors.toml"
printf 'third-party palette\n' > "$tmp/external/collection/colors.toml"
ln -s "$tmp/external/collection" "$home/.config/omarchy/themes/collection"
printf '.config/omarchy/themes\n' >> "$root/env/dotfiles.manifest"
theme_apply_preview="$(run plan apply)"
[[ "$theme_apply_preview" == *".config/omarchy/themes/authored/colors.toml"* ]]
[[ "$theme_apply_preview" != *"collection"* && "$theme_apply_preview" != *"third-party palette"* ]]
run apply > "$tmp/theme-apply.out"
[[ "$(cat "$home/.config/omarchy/themes/authored/colors.toml")" == 'authored palette' ]]
[[ -L "$home/.config/omarchy/themes/collection" ]]
printf 'live authored edit\n' > "$home/.config/omarchy/themes/authored/colors.toml"
theme_capture_preview="$(run capture --dry-run)"
[[ "$theme_capture_preview" == *"would-capture: .config/omarchy/themes/authored/colors.toml"* ]]
[[ "$theme_capture_preview" != *"collection"* && "$theme_capture_preview" != *"third-party palette"* ]]
# The same containment guard still rejects arbitrary outward links outside the
# explicitly external-theme boundary.
ln -s "$tmp/external/collection/colors.toml" "$home/.config/app/outward.conf"
if run capture --dry-run > "$tmp/non-theme-link.out" 2>&1; then
  printf 'expected non-theme outward symlink rejection\n' >&2; exit 1
fi
[[ "$(cat "$root/env/.config/omarchy/themes/authored/colors.toml")" == 'authored palette' ]]
unlink "$home/.config/app/outward.conf"
sed -i '$d' "$root/env/dotfiles.manifest"
rm -rf "$root/env/.config/omarchy/themes" "$home/.config/omarchy/themes"

# Capture shows a diff, backs up env changes, replaces a final symlink itself,
# and restore reverses the mirror update.
printf 'captured user edit\n' > "$home/.config/app/main.conf"
unlink "$home/.config/app/link.conf"
printf 'regular replacement\n' > "$home/.config/app/link.conf"
preview="$(run capture --dry-run)"
[[ "$preview" == *"would-capture: .config/app/main.conf"* ]]
run capture > "$tmp/capture.out"
capture_backup="$(sed -n 's/^Capture backup: //p' "$tmp/capture.out")"
[[ "$(cat "$root/env/.config/app/main.conf")" == 'captured user edit' ]]
[[ ! -L "$root/env/.config/app/link.conf" ]]
run restore "$capture_backup" >/dev/null
[[ "$(cat "$root/env/.config/app/main.conf")" == one ]]
[[ -L "$root/env/.config/app/link.conf" ]]

# Replacement backups restore old live data. Missing-path snapshots record new
# files so restore removes files created by apply.
printf 'live changed\n' > "$home/.config/app/main.conf"
printf 'two\n' > "$root/env/.config/app/main.conf"
run apply > "$tmp/replace.out"
apply_backup="$(sed -n 's/^Backups: //p' "$tmp/replace.out")"
[[ "$(cat "$home/.config/app/main.conf")" == two ]]
[[ "$(cat "$apply_backup/files/.config/app/main.conf")" == 'live changed' ]]
printf 'created\n' > "$root/env/.config/app/new.conf"
run apply > "$tmp/create.out"
create_backup="$(sed -n 's/^Backups: //p' "$tmp/create.out")"
[[ -f "$home/.config/app/new.conf" ]]
run restore "$create_backup" >/dev/null
[[ ! -e "$home/.config/app/new.conf" ]]

# Failure on a later copy rolls back files created earlier in that operation.
printf 'first\n' > "$root/env/.config/app/a-first.conf"
printf 'fail\n' > "$root/env/.config/app/z-fail.conf"
cat > "$tmp/failing-cp" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do [[ "$arg" == */env/.config/app/z-fail.conf ]] && exit 9; done
exec cp "$@"
EOF
chmod +x "$tmp/failing-cp"
if DOTFILES_CP="$tmp/failing-cp" run apply > "$tmp/failure.out" 2>&1; then
  printf 'expected injected copy failure\n' >&2; exit 1
fi
[[ ! -e "$home/.config/app/a-first.conf" ]]
[[ ! -e "$home/.config/app/z-fail.conf" ]]
failed_apply_backup="$(sed -n 's/.*backup: //p' "$tmp/failure.out" | tail -n 1)"
[[ -n "$failed_apply_backup" ]]
[[ "$(sed -n 's/^complete=//p' "$failed_apply_backup/metadata")" == no ]]

# Invalid paths and outward symlinks fail during preflight, before earlier
# sorted candidates are written.
printf 'good\n' > "$root/env/.config/app/a-good.conf"
ln -s "$tmp/outside.conf" "$root/env/.config/app/z-escape.conf"
if run apply > "$tmp/escape.out" 2>&1; then printf 'expected escaping symlink rejection\n' >&2; exit 1; fi
[[ ! -e "$home/.config/app/a-good.conf" ]]
unlink "$root/env/.config/app/z-escape.conf"
printf '../outside\n' >> "$root/env/dotfiles.manifest"
if run plan apply > "$tmp/traversal.out" 2>&1; then printf 'expected traversal rejection\n' >&2; exit 1; fi
[[ ! -e "$home/.config/app/a-good.conf" ]]
sed -i '$d' "$root/env/dotfiles.manifest"

# A backup copy failure leaves an explicitly incomplete snapshot which public
# restore rejects. Its recorded entries remain usable by operation rollback.
cat > "$tmp/failing-backup-cp" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do [[ "$arg" == */home/.config/app/main.conf ]] && exit 8; done
exec cp "$@"
EOF
chmod +x "$tmp/failing-backup-cp"
if DOTFILES_CP="$tmp/failing-backup-cp" run backup > "$tmp/backup-failure.out" 2>&1; then
  printf 'expected injected backup failure\n' >&2; exit 1
fi
partial_backup="$(sed -n 's/.*incomplete snapshot retained: //p' "$tmp/backup-failure.out" | tail -n 1)"
[[ -n "$partial_backup" && -f "$partial_backup/metadata" ]]
[[ "$(sed -n 's/^complete=//p' "$partial_backup/metadata")" == no ]]
if run restore "$partial_backup" > "$tmp/incomplete-restore.out" 2>&1; then
  printf 'expected incomplete restore rejection\n' >&2; exit 1
fi
[[ "$(cat "$home/.config/app/main.conf")" == two ]]

# A captured dangling relative symlink is restored as a symlink. Its target is
# checked at the destination and need not be present in the backup payload.
ln -s old-missing.conf "$root/env/.config/app/dangling.conf"
ln -s never-created.conf "$home/.config/app/dangling.conf"
run capture > "$tmp/dangling-capture.out"
dangling_backup="$(sed -n 's/^Capture backup: //p' "$tmp/dangling-capture.out")"
[[ -L "$root/env/.config/app/dangling.conf" ]]
[[ "$(readlink "$root/env/.config/app/dangling.conf")" == never-created.conf ]]
unlink "$root/env/.config/app/dangling.conf"
run restore "$dangling_backup" >/dev/null
[[ -L "$root/env/.config/app/dangling.conf" ]]
[[ "$(readlink "$root/env/.config/app/dangling.conf")" == old-missing.conf ]]
[[ ! -e "$root/env/.config/app/never-created.conf" ]]

# Host overlays use separate backup folders and restore correctly without the
# caller restating the host. Host capture backups also restore the right source.
mkdir -p "$root/env/hosts/laptop/.config/app"
printf '.config/app/host.conf\n' > "$root/env/hosts/laptop/dotfiles.manifest"
printf 'host one\n' > "$root/env/hosts/laptop/.config/app/host.conf"
run apply --host laptop > "$tmp/host-apply.out"
[[ "$(cat "$home/.config/app/host.conf")" == 'host one' ]]
printf 'host two\n' > "$root/env/hosts/laptop/.config/app/host.conf"
run apply --host laptop > "$tmp/host-replace.out"
host_backup="$(sed -n 's/^Backups: //p' "$tmp/host-replace.out")"
[[ "$host_backup" == "$state/backups/laptop/"* ]]
run restore "$host_backup" >/dev/null
[[ "$(cat "$home/.config/app/host.conf")" == 'host one' ]]
printf 'live host edit\n' > "$home/.config/app/host.conf"
run capture --host laptop > "$tmp/host-capture.out"
host_capture="$(sed -n 's/^Capture backup: //p' "$tmp/host-capture.out")"
[[ "$(cat "$root/env/hosts/laptop/.config/app/host.conf")" == 'live host edit' ]]
run restore "$host_capture" >/dev/null
[[ "$(cat "$root/env/hosts/laptop/.config/app/host.conf")" == 'host two' ]]

# Explicit prune is limited to previously managed paths and is itself restorable.
printf 'retired\n' > "$root/env/.config/app/retired.conf"
run apply >/dev/null
unlink "$root/env/.config/app/retired.conf"
run prune .config/app/retired.conf > "$tmp/prune.out"
[[ ! -e "$home/.config/app/retired.conf" ]]
prune_backup="$(sed -n 's/^Prune backup: //p' "$tmp/prune.out")"
run restore "$prune_backup" >/dev/null
[[ "$(cat "$home/.config/app/retired.conf")" == retired ]]

# The sync workflow is constrained to the canonical main checkout and uses a
# fixed capture/commit/push contract. A fake Git executable keeps the fixture
# fully local and proves it cannot publish real data.
sync_home="$tmp/sync-home"
sync_root="$sync_home/personal/projects/dotfiles"
sync_live="$tmp/sync-live"
sync_state="$tmp/sync-state"
fake_bin="$tmp/fake-bin"
mkdir -p "$sync_root/scripts" "$sync_root/env/.config/app" "$sync_root/env/hosts/omarchy-workstation/.config/app" "$sync_live" "$fake_bin"
cp "$repo/scripts/envctl" "$sync_root/scripts/envctl"
cp "$repo/scripts/sync.sh" "$sync_root/scripts/sync.sh"
printf '.config/app\n' > "$sync_root/env/dotfiles.manifest"
printf '.config/app/host.conf\n' > "$sync_root/env/hosts/omarchy-workstation/dotfiles.manifest"
printf 'authored\n' > "$sync_root/env/hosts/omarchy-workstation/.config/app/host.conf"
cat > "$fake_bin/git" <<'EOF'
#!/usr/bin/env bash
set -e
shift 2
case "$*" in
  'rev-parse --show-toplevel') printf '%s\n' "$SYNC_ROOT" ;;
  'rev-parse --absolute-git-dir') printf '%s/.git\n' "$SYNC_ROOT" ;;
  'branch --show-current') printf 'main\n' ;;
  'remote get-url origin') printf 'git@github.com:BrenoCRSilva/dev.git\n' ;;
  'diff --cached --check') exit 0 ;;
  'diff --cached --quiet') exit 1 ;;
  'add -A -- env scripts README.md .gitignore docs') printf 'add\n' >> "$SYNC_GIT_LOG" ;;
  'commit -m automated dev commit') printf 'commit automated dev commit\n' >> "$SYNC_GIT_LOG" ;;
  'push origin main') printf 'push origin main\n' >> "$SYNC_GIT_LOG" ;;
  *) printf 'unexpected fake git invocation: %s\n' "$*" >&2; exit 99 ;;
esac
EOF
chmod +x "$fake_bin/git"
SYNC_GIT_LOG="$tmp/git.log" SYNC_ROOT="$sync_root" HOME="$sync_home" DOTFILES_HOME="$sync_live" DOTFILES_STATE_DIR="$sync_state" PATH="$fake_bin:$PATH" \
  "$sync_root/scripts/sync.sh" > "$tmp/sync.out"
[[ "$(cat "$sync_root/env/hosts/omarchy-workstation/.config/app/host.conf")" == 'authored' ]]
[[ "$(cat "$tmp/git.log")" == $'add\ncommit automated dev commit\npush origin main' ]]
if HOME="$sync_home" "$root/scripts/envctl" sync > "$tmp/noncanonical-sync.out" 2>&1; then
  printf 'expected sync to reject a task/noncanonical checkout\n' >&2; exit 1
fi
[[ "$(cat "$tmp/noncanonical-sync.out")" == *'allowed only from the canonical checkout'* ]]

printf 'envctl fixture checks passed\n'
