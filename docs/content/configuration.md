+++
title = "Configuration"
weight = 2
description = "Every option on services.nixos-update-manager, and the flags behind them."
+++

Everything is configured through `services.nixos-update-manager`. Only
`flakePath` is required; the rest have defaults that work.

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

## Options

| Option | Type | Default | Purpose |
|---|---|---|---|
| `enable` | bool | `false` | Run the daemon as a user service bound to `graphical-session.target`. |
| `flakePath` | string | *required* | Git checkout of the flake to update and merge back into. |
| `branch` | string | `"nixos-update"` | Branch the update is built on, in a worktree of its own. Fast-forwarded into `main` after a successful apply. |
| `checkInterval` | null or span | `null` | Check on this interval unasked (`"30m"`, `"6h"`, `"1h30m"`, `"1d"`). Null means only from the tray. |
| `autoBuild` | bool | `false` | Build as soon as a scheduled check finds an update. Applying is never automatic. |
| `terminal` | null or package | `null` | Terminal the troubleshooting entries open in. Null falls back to `$TERMINAL`; with neither, those entries are not offered. |
| `terminalArgs` | list of string | `[ "-e" ]` | Arguments that make `terminal` run a command. `[ ]` for a terminal that takes it positionally. |
| `editor` | null or string | `null` | Editor for the failure report, resolved from `PATH`. Null falls back to `$EDITOR`, then `nvim`. |
| `claudePackage` | null or package | `null` | Claude Code for "Troubleshoot with Claude", passed by absolute path. Null resolves `claude` from `PATH`. |
| `icons.<state>` | null or string | `null` | `#rrggbb` for one state's icon. Null keeps the icon package's own colour. |
| `iconPackage` | package | derived | The rendered icon theme the daemon is pointed at. Defaults to the icons package with the non-null `icons.*` applied. |
| `package` | package | this flake's | The daemon package. |

## The checkout and the branch

`flakePath` must be a git checkout that declares
`nixosConfigurations.<hostname>` and `homeConfigurations."<user>@<hostname>"`.
It is a *path*, not a flake reference: the daemon runs git in it.

The daemon never touches your working copy. It keeps a `git worktree` of the
checkout on `branch` under `~/.cache/nixos-update-manager/worktree`, runs
`nix flake update` there, and builds from that. After an apply succeeds, the
lock bump is fast-forwarded from `branch` into `main`, leaving the checkout as
if you had updated and committed it yourself.

The consequence is the blocked state: any output from
`git status --porcelain --untracked-files=all` in your checkout blocks checks,
builds and applies, because the build would not see that work and the merge
back would fight it. The daemon says so once, re-polls every 30 seconds, and
clears itself when you commit.

## Checking on a schedule

```nix
checkInterval = "6h";
autoBuild = true;
```

`checkInterval` is a run of `<number><unit>` pairs — `s`, `m`, `h`, `d` — so
`"90s"`, `"6h"` and `"1h30m"` are all valid and zero is not. A check evaluates
only. It puts nothing in the store, which is what makes an interval this short
reasonable.

The scheduler lives inside the daemon rather than in a systemd timer, because
it has to know daemon state: it never starts a check during a build or an
apply, or while the checkout is blocked, and a manual check resets the clock.
A scheduled check that finds nothing new is silent — the same `main` revision
with the same `flake.lock` is the same update, so it notifies only on something
genuinely new.

`autoBuild` extends that to the build: a scheduled check that finds an update
goes straight on to building it, and you get the notification with the update
already built. Applying is never automatic, with or without this.

## Troubleshooting entries

When a check, build or apply fails, the menu and the error notification grow
*Open failure report* and *Troubleshoot with Claude*. Both write the same
Markdown to `~/.cache/nixos-update-manager/troubleshoot.md` — `git status`, the
branch revisions, the daemon's own journal for this boot, the error chain —
and open it in a terminal. These four options are what they open it *with*:

```nix
terminal = pkgs.alacritty;
terminalArgs = [ "-e" ];        # [ "-e" ] suits most; [ ] for kitty-style
editor = "nvim";
claudePackage = pkgs.claude-code;
```

`terminal` is the one that gates the rest. With no `terminal` and no
`$TERMINAL` in the environment, neither entry is shown at all, rather than
shown and broken.

`editor` is deliberately a `PATH`-resolved string rather than a package: the
report should open in whichever editor your home profile installs, not in a
second copy from the store. `claudePackage` is the opposite — an absolute store
path, so it does not depend on the unit's `PATH`. The Claude entry opens an
interactive session rooted in the flake checkout with the report already
submitted as its first prompt.

## Icons and colours

The daemon ships its own icons and looks up no freedesktop icon names at all,
so the tray survives a broken Qt or GTK icon theme. Every status icon is the
same silhouette — an arrow landing on a baseline — and the state is carried by
the arrowhead, the baseline and the colour.

Each state's colour is an option. Null keeps the icon package's default, so you
can respell one without restating the palette:

```nix
icons = {
  idle = "#cdd6f4";
  checking = "#89b4fa";
  upToDate = "#a6e3a1";
  updatesAvailable = "#f9e2af";
  applying = "#89dceb";
  building = "#94e2d5";
  error = "#f38ba8";
  blocked = "#fab387";
  menu = "#cdd6f4";     # the menu glyphs, which take no meaning from hue
};
```

The hues are chosen so the temperature says whose turn it is: cool while the
daemon is working, warm when it is yours.

Setting any of these re-renders the icons package, which is a `runCommand`
around `resvg` — a recolour does not rebuild the Rust crate. That is also why
the daemon takes the icon theme as a runtime path rather than baking it in.

`iconPackage` is the escape hatch, and it is the one that matters while the
module is enabled: the unit always passes `--icon-dir`, so overriding
`nixos-update-manager-icons` inside `package` only changes what the binary
falls back to on its own. To render the icons yourself:

```nix
iconPackage = pkgs.nixos-update-manager-icons.override {
  error = "#ff0000";
  building = "#94e2d5";
};
```

## Command line

The module turns the options above into flags, but the daemon runs by hand too.
Each flag's environment-variable equivalent is what a unit file of your own
would set.

```
nixos-update-manager --flake PATH [--branch NAME] [--host NAME] [--user NAME]
    [--cache-dir DIR] [--icon-dir DIR] [--terminal CMD] [--terminal-arg ARG]...
    [--editor CMD] [--claude PATH] [--review-dialog PATH]
    [--check-interval SPAN] [--auto-build]
```

| Flag | Environment | Default |
|---|---|---|
| `--flake PATH` | `NIXOS_UPDATE_FLAKE` | *required* |
| `--host NAME` | `NIXOS_UPDATE_HOST` | the machine's hostname |
| `--user NAME` | `NIXOS_UPDATE_USER` | `$USER` |
| `--branch NAME` | — | `nixos-update` |
| `--cache-dir DIR` | — | `$XDG_CACHE_HOME/nixos-update-manager` |
| `--icon-dir DIR` | `NIXOS_UPDATE_ICON_DIR` | set by the package's wrapper |
| `--terminal CMD` | `NIXOS_UPDATE_TERMINAL` | `$TERMINAL` |
| `--terminal-arg ARG` | — | `-e`, repeatable; `--terminal-arg ""` for none |
| `--editor CMD` | `NIXOS_UPDATE_EDITOR` | `$EDITOR`, then `nvim` |
| `--claude PATH` | `NIXOS_UPDATE_CLAUDE` | `claude` from `PATH` |
| `--review-dialog PATH` | `NIXOS_UPDATE_REVIEW_DIALOG` | `nixos-update-review` beside the daemon |
| `--check-interval SPAN` | `NIXOS_UPDATE_CHECK_INTERVAL` | off |
| `--auto-build` | `NIXOS_UPDATE_AUTO_BUILD` | off |

`--host` and `--user` name the flake attributes to build:
`nixosConfigurations.<host>` and `homeConfigurations."<user>@<host>"`. Override
them when the attribute names do not match the machine — a shared configuration
built under one hostname, say.

Passing any `--terminal-arg` replaces the default rather than adding to it, so
a terminal that takes its command positionally is spelled `--terminal-arg ""`;
the empty argument is dropped rather than passed on. In the module that is
`terminalArgs = [ ]`.
