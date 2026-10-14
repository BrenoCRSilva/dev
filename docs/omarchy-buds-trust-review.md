# Omarchy Buds trust and compatibility review

## Assessment

**Do not enable the currently released v0.2.2 yet.** The complete source review at commit [`02c27e8`](https://github.com/dgalarza/omarchy-buds/tree/02c27e8b5eb4c84d03cab50bf3802dd57a3b5ebe) found no obvious malicious behavior. However, that release has a concrete unbounded-input/process-I/O weakness. The author's [PR #1](https://github.com/dgalarza/omarchy-buds/pull/1), still open as of 2026-10-13 and not part of v0.2.2, adds bounded file and process handling plus tests for symlink, special-file, oversized-input, and hung-output cases. Prefer waiting for that hardening in a release, or a separately reviewed backport.

This is a judgment about the reviewed commit, not a guarantee about later code or the behavior of GalaxyBudsClient. The v0.2.2 tag is unsigned; its commit is identifiable, but the tag itself does not establish a verified publisher signature.

## What `omarchy plugin add` does here

Installed Omarchy is `4.0.4-1`. The relevant implementation is `/usr/share/omarchy/bin/omarchy-plugin-add`, with update and schema checks in `omarchy-plugin-update` and `omarchy-plugin-validate` (all owned by the installed `omarchy` package).

- `omarchy plugin add URL` checks the URL, clones into a temporary directory under `~/.config/omarchy/plugins`, validates the manifest/entry points and rejects symlinks, then moves the checkout to the manifest ID. It does **not** run the repository's `setup` script, install hooks, invoke sudo, or otherwise execute setup code.
- It rescans plugin metadata after cloning. It does not enable the new plugin automatically in noninteractive/`--yes` mode unless `--enable` is supplied. In an interactive terminal, it asks whether to enable it after cloning; answering yes loads the plugin into the long-running shell.
- A third-party enabled plugin is QML/JavaScript running in `omarchy-shell` without an OS sandbox. Omarchy gives third-party code capability-scoped host facades and protects authentication services, but this is not process isolation; visual plugin objects share the host QML scene. Enabling code grants it the shell process's user-level environment/permissions. The installed contract is documented in `/usr/share/omarchy/shell/README.md` and implemented in `/usr/share/omarchy/shell/services/PluginRegistry.qml` and `shell.qml`.
- `omarchy plugin update ID` fetches `origin HEAD`, shows a diff and asks before fast-forwarding unless `--yes` is used. It then validates the manifest and rolls back if validation fails. The command has no immutable revision pin option; a checkout follows its remote branch, and `--yes` bypasses the review prompt. Pinning requires ordinary Git operations in the plugin directory.

Consequently, `add` is a relatively cautious **file acquisition and manifest-validation** path, not a security review. It does not protect the shell once the plugin is enabled, nor does its prompt substitute for checking a specific commit.

## Reviewed plugin behavior

The independent full-source review covered the plugin's QML, JavaScript, `setup`, and C# GalaxyBudsClient script at the v0.2.2 commit:

- The UI and service use a fixed allowlist of six action IDs, passed as fixed arguments to `galaxybudsclient action -e`. `busctl` is used only for session-bus status/monitor calls. The service checks action IDs again and does not interpolate user-controlled JSON into a shell command.
- The `setup` script only copies the C# status hook to the GalaxyBudsClient XDG scripts location. The hook decodes status/acknowledgement data and atomically writes a status JSON file under a private mode-0700 state directory with mode-0600 file permissions. The snapshot includes the device name/address and battery/control state. The C# hook itself did not launch processes, access credentials, or make network requests.
- The reviewed tree has no submodules, symlinks, bundled executables, or binary payloads; its GitHub Actions use SHA-pinned actions and the project declares no NuGet dependencies.
- The copied GalaxyBudsClient hook is separate from the Omarchy plugin checkout. Updating the plugin does not update that installed hook; rerunning `setup` and restarting GalaxyBudsClient would be needed to refresh it. The hook also needs explicit cleanup if one later removes the integration.

These findings cover only the exact reviewed source snapshot; they do not certify the maintainer, future commits, or GalaxyBudsClient itself. The project's integration contract depends on GalaxyBudsClient's scripting support, which is less stable than Omarchy's plugin manifest.

## Fit on this host

This host is x86_64 and has BlueZ/bluez-utils 5.87-2 and PipeWire 1.6.8-1. No GalaxyBudsClient command, package, desktop entry, or Flatpak is installed, and no local client version is available. The plugin does not supply that client, so it cannot provide its intended status/control integration on this host yet. The official [GalaxyBudsClient README](https://github.com/timschneeb/GalaxyBudsClient/blob/master/README.md) documents Linux builds and the client integration surface; that separate application was not installed or run for this assessment.

## Scope

Read-only inspection only. No plugin add, setup, enable, update, client launch, or configuration change was performed. Installed-source evidence is from Omarchy `4.0.4-1`; upstream code findings are limited to the v0.2.2 commit above and the currently open hardening PR.
