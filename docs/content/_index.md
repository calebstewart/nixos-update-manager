+++
title = "Overview"
sort_by = "weight"
template = "index.html"
page_template = "page.html"
+++

> [!WARNING]
> This is built for my own machines and it is entirely AI slop. It should work
> generally, but it is not a supported tool: no stability promises, no
> compatibility promises, and no support for anyone else's setup. Use at your
> own risk.

`nixos-update-manager` is a system-tray daemon for a NixOS machine that is
managed from a git flake. It checks whether `nix flake update` would change
anything, builds the new system and home generation while drawing the progress
into its own tray icon, and applies the result when you ask it to. **Nothing is
ever applied automatically.**

It is two programs. `nixos-update-manager` owns a StatusNotifierItem tray icon
and its menu; `nixos-update-review` is a GTK4/libadwaita dialog that shows what
an update changes — twice, once before you spend anything building it and once
before you apply it.

If you already know what it is: [Installation](@/installation.md) is the flake
input and the Home-Manager module, and [Configuration](@/configuration.md) is
every option there is.

## The three stages

An update moves through three explicit stages, and the tray menu offers exactly
the action for the stage it is in.

**Check** is evaluation only. The daemon bumps `flake.lock` in a private
worktree of your checkout, compares `environment.systemPackages` and
`home.packages` old-against-new by name and version, and dry-runs a build of
both toplevels to produce a plan: *N paths to fetch (X MiB), M derivations to
build locally*. It takes seconds and puts nothing in the store, which is what
makes a periodic check cheap enough to leave running.

**Build** runs the two `nix build`s and streams their progress. The tray icon
fills in as paths are fetched and derivations are built, and the notification
carries the same fraction. The bar counts what the dry run promised rather than
nix's shifting byte totals, so it is exact, monotonic and ends at 100 %. A build
can be cancelled from the menu.

**Review and apply** shows the closure diff against what is running now, and
offers four ways to apply it:

- *system + home* — both activated now;
- *home now, system on next boot* — the system generation becomes the boot
  default without switching the running one;
- *home only*;
- *system only*.

A partial apply leaves the other half pending, so you can finish it later from
the same menu. The system half goes through `run0`, so the privilege prompt is
your desktop's own polkit agent. Once an update is applied, the lock bump is
fast-forwarded into `main` — the checkout ends up exactly as if you had run
`nix flake update` and committed it yourself.

Between stages the update is persisted, so a daemon restart, a reboot, or a
re-check that finds nothing new all leave it where it was.

## Features

- **Eval-only checks**, on demand from the tray or on a fixed interval, with an
  optional automatic build when a scheduled check finds something.
- **A progress bar drawn into the tray icon**, 21 frames of it, exact and
  monotonic because it counts the dry run's own totals.
- **A review dialog** listing the flake inputs that moved and every package's
  `old → new` version: before the build, the installed-package changes and the
  build plan; after it, the full closure diff and the four apply modes.
- **A blocked state.** Any uncommitted or untracked change in the checkout
  blocks checks, builds and applies, with an icon of its own, until you commit.
  The daemon never stashes: it builds from what is committed on `main`, so
  uncommitted work would be invisible to the build and then fought over when the
  lock bump is merged back. It re-polls every 30 seconds, so the tray clears
  itself once you commit.
- **Failure reports.** A failed check, build or apply grows two entries on the
  menu and the error notification: *Open failure report* and *Troubleshoot with
  Claude*. Both write the same Markdown — `git status`, the branch revisions,
  the daemon's own journal, the error chain — and open it in your terminal,
  either in your editor or as the opening prompt of a Claude Code session rooted
  in the checkout.
- **Its own icons**, sixteen SVG sources rendered at build time and recoloured
  per state from [options you control](@/configuration.md#icons-and-colours). No
  freedesktop icon names are used anywhere, so a broken Qt or GTK icon theme
  cannot leave the tray blank.
- **Notifications at every transition**, with action buttons where they make
  sense: Build, Review, Apply now.

## What it needs

NixOS with flakes, managed from a git checkout; standalone Home-Manager;
systemd 256 or later for `run0`, with a polkit agent in the session; a
StatusNotifierItem host and a notification daemon. The
[requirements](@/installation.md#requirements) are spelled out in full on the
installation page.
