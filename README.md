# nixos-update-manager

> [!WARNING]
> This is built for my own machines and it is entirely AI slop. It should work
> generally, but it is not a supported tool: no stability promises, no
> compatibility promises, and no support for anyone else's setup. Use at your
> own risk.

A system-tray daemon for NixOS machines managed from a git flake. It checks
whether `nix flake update` would change anything, builds the new system and
home generation while showing progress in the tray icon, and applies the
result on request. Nothing is ever applied automatically.

The daemon (`nixos-update-manager`) owns a StatusNotifierItem tray icon and a
menu; a separate GTK4/libadwaita dialog (`nixos-update-review`) shows what an
update changes before you build it and before you apply it.

Full documentation, including installation and every configuration option:
<https://calebstew.art/nixos-update-manager>.

## What an update looks like

An update goes through three explicit stages, and the tray menu shows exactly
the action for the stage it is in.

1. **Check** is evaluation only. The daemon bumps `flake.lock` in a private
   worktree of your checkout, compares `environment.systemPackages` and
   `home.packages` old-vs-new by name and version, and dry-runs a build of both
   toplevels to produce a plan: *N paths to fetch (X MiB), M derivations to
   build locally*. This takes seconds and puts nothing in the store, which is
   what makes periodic checks cheap.
2. **Build** runs the two `nix build`s and streams their progress. The tray
   icon itself fills in as paths are fetched and derivations are built, and a
   notification carries the same fraction. A build can be cancelled from the
   menu.
3. **Review / Apply** shows the closure diff against what is currently running
   and offers four ways to apply it:
   - *system + home*: both activated now;
   - *home now, system on next boot*: the system generation becomes the boot
     default without switching the running one;
   - *home only*;
   - *system only*.

   A partial apply leaves the other half pending, so it can be applied later
   from the same menu.

   The system half runs through `run0`, so the privilege prompt is the
   desktop's own polkit agent. Once applied, the lock bump is fast-forwarded
   from the update branch into `main`, so the checkout ends up exactly as if
   you had run `nix flake update` and committed it yourself.

Between stages the update is persisted, so a daemon restart, a re-check that
finds nothing new, or a reboot leaves it where it was.

## Features

- Eval-only checks, on demand from the tray or on a fixed interval, with an
  optional automatic build when a scheduled check finds something.
- A build progress bar drawn into the tray icon (21 frames), exact and
  monotonic because it counts what the dry run promised, not nix's shifting
  byte totals.
- A review dialog listing the flake inputs that moved and every package's
  `old → new` version, before the build (installed packages and the plan) and
  after it (the full closure diff).
- A **Blocked** state: any uncommitted or untracked change in the checkout
  blocks checks, builds and applies, with its own icon, until you commit. The
  daemon never stashes.
- Failure reports: a failed check, build or apply adds "Open failure report"
  and "Troubleshoot with Claude" to the menu and the error notification. Both
  write the same Markdown report (git status, branch revisions, the daemon's
  own journal, the error chain) and open it in your terminal, either in your
  editor or as the opening prompt of a Claude Code session rooted in the
  checkout.
- Its own icon set, recoloured per state from a small set of colours, with no
  dependency on the ambient icon theme.
- Desktop notifications at every transition, with action buttons where they
  make sense (Build, Apply now, Review).

## Requirements

- NixOS with flakes, managed from a git checkout that declares
  `nixosConfigurations.<hostname>` and `homeConfigurations."<user>@<hostname>"`
  (the host defaults to the machine's hostname and the user to `$USER`; both
  can be overridden on the command line).
- Standalone home-manager for the user's home generation.
- systemd with `run0` (systemd 256 or later) and a polkit agent in the session.
- A StatusNotifierItem host (most bars and shells) and a notification daemon.
- A clean working tree at the time of a check: the daemon builds from what is
  committed on `main`.

## Installation

Add the flake as an input and import its home-manager module:

```nix
{
  inputs.nixos-update-manager.url = "github:calebstewart/nixos-update-manager";

  # ...

  homeConfigurations."alice@laptop" = home-manager.lib.homeManagerConfiguration {
    modules = [
      inputs.nixos-update-manager.homeModules.default
      {
        services.nixos-update-manager = {
          enable = true;
          flakePath = "/home/alice/nixos";
        };
      }
    ];
  };
}
```

`flakePath` is the only required option. A fuller configuration:

```nix
services.nixos-update-manager = {
  enable = true;
  flakePath = "${config.home.homeDirectory}/nixos";
  branch = "nixos-update";

  checkInterval = "6h";
  autoBuild = true;

  terminal = pkgs.alacritty;
  terminalArgs = [ "-e" ];
  editor = "nvim";
  claudePackage = pkgs.claude-code;

  icons = {
    error = "#f38ba8";
    updatesAvailable = "#f9e2af";
  };
};
```

### Options

| Option | Default | Purpose |
|---|---|---|
| `enable` | `false` | Run the daemon as a user service bound to `graphical-session.target`. |
| `flakePath` | *required* | Git checkout of the flake to update and merge back into. |
| `branch` | `"nixos-update"` | Branch the update is built on. Fast-forwarded into `main` after a successful apply. |
| `checkInterval` | `null` | Check on this interval without being asked (`"30m"`, `"6h"`, `"1h30m"`, `"1d"`). Null means only from the tray. |
| `autoBuild` | `false` | Build as soon as a scheduled check finds an update. Applying is never automatic. |
| `terminal` | `null` | Terminal the troubleshooting entries open in. Null falls back to `$TERMINAL`; with neither, the entries are not offered. |
| `terminalArgs` | `[ "-e" ]` | Arguments that make the terminal run a command. Empty for one that takes it positionally. |
| `editor` | `null` | Editor for the failure report, resolved from PATH. Null falls back to `$EDITOR`, then `nvim`. |
| `claudePackage` | `null` | Claude Code for "Troubleshoot with Claude". Null resolves `claude` from PATH. |
| `icons.<state>` | `null` | Colour of the icon for `idle`, `checking`, `upToDate`, `updatesAvailable`, `applying`, `building`, `error`, `blocked` or the `menu` glyphs. Null keeps the built-in colour. |
| `iconPackage` | derived | The rendered icon theme; defaults to the icons package with the non-null `icons.*` colours applied. |
| `package` | this flake's | The daemon package. |

The flake also exports `packages.<system>.{nixos-update-manager,nixos-update-manager-icons}`
and `overlays.default`, which adds both to `pkgs` under the same names.

## How it works

Everything the daemon touches outside your checkout lives in
`~/.cache/nixos-update-manager`:

- `worktree/` is a `git worktree` of your flake on the update branch. Checks
  run `nix flake update` there, never in your working copy.
- `result-system` and `result-home` are the out-links of a built update.
- `state.json` is the pending update, so it survives restarts.
- `troubleshoot.md` is the latest failure report.

A check compares the `main` revision and the `flake.lock` contents against the
pending update, so re-checking the same state is a no-op and a scheduled check
only notifies when something genuinely changed.

Applying the system half runs `nix-env --set` on the system profile followed
by `switch-to-configuration` (`switch` or `boot`) through a small helper
installed in `libexec`, under `run0`. Exit status 4 from
`switch-to-configuration` is treated as a finished switch with a warning, since
by then the profile, boot entry and activation are done and the status only
reports that some unit is failed. The home half runs in a transient
`systemd-run --user` unit rather than as a child of the daemon, because the
new home generation nearly always restarts the daemon's own service part-way
through activation.

**Blocked** means `git status --porcelain --untracked-files=all` printed
something. The worktree builds from committed `main`, so uncommitted work would
be invisible to the build and then fought over when the lock bump is merged
back. The daemon re-polls every 30 seconds, so the tray clears itself once you
commit.

## Icons

The tray and menu icons are rendered at build time from SVG sources with
[resvg](https://github.com/linebender/resvg). Every state shares one
silhouette (an arrow landing on a baseline); state is carried by the
arrowhead, the baseline and the colour. The colours are arguments of the icons
derivation, so they can be changed without rebuilding the daemon:

```nix
pkgs.nixos-update-manager-icons.override {
  error = "#ff0000";
  building = "#94e2d5";
}
```

The home-manager module's `icons.*` options are the same knobs.

## Command line

The daemon is normally started by the module, but runs by hand too. Every flag
has an environment-variable equivalent for use in a unit file:

```
nixos-update-manager --flake ~/nixos [--branch nixos-update] [--host NAME] [--user NAME]
    [--icon-dir DIR] [--terminal CMD] [--terminal-arg ARG]... [--editor CMD]
    [--claude PATH] [--check-interval SPAN] [--auto-build] [--cache-dir DIR]
```

## Development

```bash
nix develop            # cargo, rustc, clippy, rustfmt, rust-analyzer and the GTK stack
cargo test             # 70 unit tests, no network or store access needed
cargo clippy
nix fmt                # nixfmt for *.nix, rustfmt for *.rs
nix flake check        # builds both packages (running the tests) and checks formatting
```

The dev shell exports `NIXOS_UPDATE_APPLY_HELPER` and `NIXOS_UPDATE_ICON_DIR`
pointing at store copies, so `cargo run -- --flake ~/nixos` behaves like the
installed daemon. The review dialog is found next to the daemon binary, so
`cargo build` (not just `cargo run`) is needed once for the Review entry to
appear from a dev build.

## License

MIT. See [LICENSE](LICENSE).
