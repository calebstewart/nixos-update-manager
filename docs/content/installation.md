+++
title = "Installation"
weight = 1
description = "The flake input, the Home-Manager module, and how to check it came up."
+++

The daemon is installed as a Home-Manager user service. The module is the
supported path: it writes the systemd unit, passes the rendered icon theme, and
turns every option on the [configuration](@/configuration.md) page into a
command-line flag.

## Requirements

- **NixOS with flakes**, managed from a **git checkout** that declares
  `nixosConfigurations.<hostname>` and
  `homeConfigurations."<user>@<hostname>"`. The host defaults to the machine's
  hostname and the user to `$USER`; both can be overridden.
- **Standalone Home-Manager** for the user's home generation. The daemon
  activates the two halves separately, which is what the four apply modes are.
- **systemd 256 or later**, for `run0`. The privileged half of an apply runs
  through it, so the prompt is your desktop's own polkit agent — which has to be
  running in the session.
- **A StatusNotifierItem host** — most bars and desktop shells are one — and a
  notification daemon.
- **A clean working tree** when a check runs. The daemon builds from what is
  committed on `main`; anything uncommitted puts it in the blocked state until
  you commit.

## Add the flake

Add the input, import `homeModules.default`, and set `flakePath`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixos-update-manager.url = "github:calebstewart/nixos-update-manager";
    nixos-update-manager.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, home-manager, nixos-update-manager, ... }:
    {
      homeConfigurations."alice@laptop" = home-manager.lib.homeManagerConfiguration {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        modules = [
          nixos-update-manager.homeModules.default
          {
            home.username = "alice";
            home.homeDirectory = "/home/alice";
            home.stateVersion = "24.11";

            services.nixos-update-manager = {
              enable = true;
              flakePath = "/home/alice/nixos";
            };
          }
        ];
      };
    };
}
```

`flakePath` is the only option with no default, because there is no sensible
default for someone else's checkout. Everything else has one — see
[Configuration](@/configuration.md).

The module is also exported as `homeManagerModules.default`, the older spelling,
for consumers that still look for it. Both are the same module.

`inputs.nixpkgs.follows` is worth setting. Without it you build the daemon
against this flake's pinned nixpkgs and pull a second copy of it into your
lock file.

## What the module installs

- The `nixos-update-manager` package into `home.packages`, which is the daemon
  and the `nixos-update-review` dialog beside it — they are two binaries of one
  crate, so they can never come from different generations.
- A `nixos-update-manager.service` user unit, `PartOf` and `WantedBy`
  `graphical-session.target`, restarted on failure. Its `ExecStart` is the
  daemon with every configured option spelled out as a flag.
- Nothing outside your home. The privileged half of an apply is a small helper
  in the package's `libexec`, invoked through `run0` at the moment it is needed.

Everything the daemon writes lives under `~/.cache/nixos-update-manager`: the
`worktree/` it checks in, the `result-system` and `result-home` out-links of a
built update, the `state.json` that carries a pending update across restarts,
and the `troubleshoot.md` of the most recent failure.

## Check that it came up

Rebuild your home generation, then:

```bash
systemctl --user status nixos-update-manager
```

A tray icon appears once the daemon has a StatusNotifierItem host to register
with. Before the first check it shows the *idle* mark; "Check for updates" in
its menu runs one.

If the icon is missing, the daemon's log is the place to look:

```bash
journalctl --user -u nixos-update-manager -f
```

The unit is bound to `graphical-session.target`. If your compositor does not
reach that target, nothing starts it — that is worth ruling out first.

## Running it by hand

The daemon takes every option as a flag, so it runs outside the module too —
useful for trying it before wiring it into a configuration:

```bash
nix run github:calebstewart/nixos-update-manager -- --flake ~/nixos
```

Run it from a terminal in the session that owns the tray. Stop the user service
first if it is already running, or the two will fight over the same worktree.
The [command-line reference](@/configuration.md#command-line) lists the flags
and their environment-variable equivalents.

## Without the module

The packages and an overlay are exported for the cases the module does not
cover:

```nix
# nixos-update-manager.packages.${system}:
#   nixos-update-manager        the daemon and the review dialog
#   nixos-update-manager-icons  the rendered icon theme
#   default                     = nixos-update-manager

# Or, to get both under those names in `pkgs`:
nixpkgs.overlays = [ nixos-update-manager.overlays.default ];
```

Installing the package alone gets you the binaries but no unit and no icon
theme on the command line — the daemon then falls back to the icons baked into
its wrapper, which is the package's own default palette.
