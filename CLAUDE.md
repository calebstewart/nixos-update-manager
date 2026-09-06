# nixos-update-manager

A tray daemon that checks, builds and applies NixOS + Home-Manager flake
updates. Rust crate at the repository root, Nix packaging under `nix/`,
icon sources under `icons/`. Built and tested only through the flake.

## Project Structure

```
flake.nix            # packages, overlay, home module, checks, formatter, devShell
Cargo.toml           # one crate, three targets: lib + two binaries
src/
├── main.rs          # the daemon: tray, worker thread, scheduler
├── lib.rs           # the wire types shared by daemon and dialog (only this)
├── bin/review.rs    # nixos-update-review, the GTK4/libadwaita dialog
├── config.rs        # clap args -> Config; installable strings
├── state.rs         # State machine + persisted PendingUpdate (state.json)
├── tray.rs          # ksni StatusNotifierItem and the contextual menu
├── notify.rs        # notify-rust notifications with action buttons
├── icons.rs         # loads the rendered PNGs into SNI pixmaps / dbusmenu icon-data
├── review.rs        # spawns the dialog, reads its choice on a detached thread
├── troubleshoot.rs  # failure report writer + editor / Claude launchers
├── cancel.rs        # SIGINT to the running nix child from the tray thread
└── updater/
    ├── mod.rs       # Worker: check / build / apply / restore
    ├── git.rs       # worktree, blocked detection, fast-forward merge
    ├── nix.rs       # nix subprocess wrappers (NIXOS_UPDATE_NIX test seam)
    ├── plan.rs      # dry-run parser -> BuildPlan
    ├── progress.rs  # --log-format internal-json parser -> fraction
    ├── roots.rs     # eval-only package diff of systemPackages / home.packages
    ├── diff.rs      # nix store diff-closures parser
    └── inputs.rs    # `nix flake update` stderr parser -> input changes
apply-system.sh      # privileged half, installed to libexec, run via run0
nix/package.nix      # buildRustPackage; wraps each binary separately
nix/icons.nix        # runCommand + resvg; colours are arguments
nix/hm-module.nix    # services.nixos-update-manager
```

## Build Commands

```bash
nix build                 # the daemon (runs cargo test in the sandbox)
nix build .#nixos-update-manager-icons
nix flake check           # both packages + treefmt --ci
nix fmt                   # nixfmt + rustfmt
nix develop               # cargo/rustc/clippy/rust-analyzer + GTK stack
cargo test                # inside the dev shell
```

The dev shell exports `NIXOS_UPDATE_APPLY_HELPER` and `NIXOS_UPDATE_ICON_DIR`
so `cargo run -- --flake <checkout>` behaves like the installed daemon.

## Conventions

- Every `--flag` has a `NIXOS_UPDATE_*` environment equivalent. `--flake` is
  required; there is no sensible default for someone else's checkout.
- No freedesktop icon names anywhere. Tray icons go out as SNI pixmaps, menu
  icons as dbusmenu `icon-data`, notifications get absolute PNG paths.
- `nix fmt` uses `nixfmt-tree` extended with rustfmt; `checks.formatting`
  runs `treefmt --ci` on the source, so an unformatted commit fails
  `nix flake check`.
- The home module takes `self` and is wrapped in flake.nix with a `_file`, so
  its options keep a source position for consumers' option documentation.
  Keep `defaultText` values as strings, never derivations.
- Nothing in `nix/` reads flake inputs; `nix/package.nix` and `nix/icons.nix`
  are plain `callPackage` derivations.

## Check, build and apply

An update goes through three explicit stages, and the tray menu shows exactly
the action for the stage it is in:

1. **Check** is evaluation only. It bumps the lock in the worktree, diffs
   `environment.systemPackages` and `home.packages` old-vs-new by name and
   version (`builtins.parseDrvName`, in the `--apply`, so the split is nix's
   own), and dry-runs a build of both toplevels for the plan: *N paths to
   fetch (X MiB), M derivations to build locally*. Seconds, and nothing lands
   in the store -- which is what makes `checkInterval` viable.
2. **Build** (`Build update` in the tray, `Build` in the notification and the
   dialog, or `autoBuild`) runs the two `nix build`s with `--log-format
   internal-json` and streams progress. The fraction is *(paths fetched +
   derivations built) / the dry run's totals* and nothing else: nix's
   `copyPaths` and `builds` activities count exactly what the dry run promised,
   so it is exact, monotonic and ends at 100 %. Nix's own `setExpected` byte
   totals are parsed and deliberately ignored -- they grow while substituters
   are queried, and a bar built on them runs backwards. Bytes are shown, never
   used. A cancel sends SIGINT to the child from the *tray thread* (the worker
   is blocked reading the pipe) and is checked before the exit status, since an
   interrupted nix exits non-zero.
3. **Review / Apply**: `diff-closures` against what is running, the four
   modes, `run0`.

Things that are the way they are on purpose:

- **The roots diff, not the derivation graph.** Diffing the `.drv` closures
  needs no build either, and was measured across two generations: 752
  "changed" names against 141 real ones, because build-time inputs (patches,
  crate sources, hooks, compilers) dominate. Restricting to installed names
  still gave ~70 % recall. The roots diff is exact for what the user asked to
  install; the closure diff after the build is the complete picture.
- **`Unchanged` is a check outcome.** The same `main` rev with the same
  `flake.lock` blob (`lock_hash`) is the same update, so a re-check leaves a
  pending update alone -- including a *built* one. That is also what lets a
  scheduled check stay silent: it notifies only on something new.
- **Progress is throttled at the source.** A five-path build emits ~7000
  records and every `tray.update` makes ksni re-hash every pixmap, so the tray
  and notification are refreshed on a whole-percent change and at most once a
  second, with the boundaries (start, between the two builds, end) forced.
- **Blocked is a state, not an error.** Any `git status --porcelain
  --untracked-files=all` output blocks check, build and apply: the worktree
  builds from committed `main`, so uncommitted work would be invisible to the
  build and then fought over when the lock bump is fast-forwarded back. The
  daemon refuses rather than stashing, says so once (notification on the
  transition only), and re-polls every 30 s so the tray clears itself after a
  commit. It is checked in `restore()` *before* state.json is validated, because
  validation discards the file on failure and a dirty checkout is no reason to
  lose a pending update.
- **The scheduler lives in the daemon, not a systemd timer.** It has to know
  daemon state (never during a build or apply, not while blocked, reset by a
  manual check), the daemon has no control socket a timer could poke, and its
  lifetime already is the session. The loop is `recv_timeout` over the worker's
  own schedule, capped at an hour because `Instant + Duration::MAX` panics.
- **A failed build leaves the update pending and unbuilt**, hidden behind the
  failure block until the next successful check -- the same convention as a
  failed apply.
- **Home activation runs in a transient unit** (`systemd-run --user --wait
  --pipe --collect`), never as a child of the daemon. The new generation
  nearly always carries a changed `nixos-update-manager.service`, and
  sd-switch stops every changed unit before it starts any -- so when the
  `activate` script sat in the daemon's cgroup, stopping the daemon killed the
  activation between those two phases and left the shell, the polkit agent and
  the daemon itself stopped with nothing to start them. The daemon can still
  be stopped before the script returns; the lock merge already happens before
  activation for that reason, and `restore()` treats a persisted update whose
  two paths are what the system runs as *applied* -- checked before
  `main_rev`, which the merge has legitimately moved -- and sends the "Update
  applied" notification the old daemon never got to.
- **Exit status 4 from `switch-to-configuration` is a finished switch, not a
  failed one.** The profile, boot entry and activation are all done by then;
  the status only says some unit is `failed` afterwards, and it lists *every*
  failed unit on the system, whether the switch touched it or not. It was
  once treated as a failure and the result was the worst of both worlds: the
  new system already running, `flake.lock` unmerged and home stale -- the
  very things a retry would then skip. (The trigger was `fwupd-refresh.timer`
  elapsing in the window where activation had `polkit.service` stopped.) The
  daemon now counts the OS half as done and carries the warning as a caveat
  on the "Update applied" notification, next to a failed lock merge. Every
  other non-zero status is still a failure.

## Review dialog

"Review changes…" opens a GTK4/libadwaita window listing the flake inputs that
moved and the per-package `old → new` versions. It is opened twice per update:
before the build (`built: false`) it shows the installed-package changes and
the plan as a banner, and its one action is `Build`; after the build it shows
the closure diff with the four apply modes on an `AdwSplitButton`. It is the
crate's **second binary** (`nixos-update-review`, `src/bin/review.rs`),
sharing `src/lib.rs` with the daemon and nothing else.

Things that are the way they are on purpose:

- **A separate process, not a window in the daemon.** The tray keeps its
  current footprint, GTK is resident only while the window is up, and a GUI
  crash cannot take the tray down. The daemon writes one line of JSON
  (`ReviewRequest`) to the child's stdin and reads one line back
  (`ReviewChoice`) on a **detached thread**, then sends an ordinary
  `Command::Apply` -- the same shape `notify.rs` already uses for the "Apply
  now" button. The stdin write is on that thread, not the worker: a large
  update exceeds the pipe buffer and would deadlock the worker against a child
  that has not started reading.
- **The dialog carries no authority.** Its entire outbound vocabulary is
  `ApplyMode` plus `Build`, exactly what the tray already sends, and
  `Worker::build` / `Worker::apply` re-check the pending state, `main_rev`, the
  lock hash and the out-links as usual. So a request that goes stale while the
  window is open produces an apply the daemon refuses, and `ReviewRequest`
  needs no rev echoed back -- which also keeps `Command` `Copy`, as `tray.rs`'s
  `Fn` closures require.
- **The wire spellings are pinned by tests** (`lib.rs`). They are the only
  contract between two binaries, so a rename that compiles on both sides would
  otherwise fail silently at runtime. `PROTOCOL_VERSION` exists because a home
  activation can leave an old daemon running against a new dialog until the
  unit restarts.
- **GTK4, not Qt.** The Rust bindings are C-ABI and mature, so there is no
  `cxx-qt` C++ glue and no libstdc++ ABI hazard between the plugin and the
  host. libadwaita picks up the desktop's named colours, so the dialog is
  themed with no plumbing of its own.
- **The window floats via a "ghost parent".** Wayland has no
  `_NET_WM_WINDOW_TYPE_DIALOG`; the only signal is `xdg_toplevel.set_parent()`,
  and GTK emits it only for a parent that has actually been *mapped*. So the
  dialog maps one that cannot be seen -- 1×1, non-resizable (so a tiling
  compositor floats it rather than tiling it), undecorated and
  `opacity 0` -- and keeps it for its lifetime. Measured on Hyprland: a plain
  toplevel is tiled full-height, `set_modal(true)` alone does nothing, and
  hiding the parent *before* presenting the child does not float it either.
  Every hide-it-afterwards variant is a timing race with a visible flash; this
  one has no race. Close the ghost with the window or the process never exits.
- **`nix flake update`'s output is on stderr**, not stdout -- nix prints the
  lock diff through its *warning* logger -- and the entries are multi-line.
  `updater/inputs.rs` parses it, leniently: this is decoration, so a nix format
  change must yield an empty list rather than break update checking.
- **`diff.rs` keeps what it used to throw away.** It parsed versions and the
  size delta only to classify a line; both are now retained. A row with **no
  versions on either side is normal** -- nix prints only a size delta when a
  package is rebuilt at the same version (6 of 33 rows in a real check) -- and
  renders as "same version, rebuilt". That is also why the size delta is shown
  despite not being version information: it is the only thing those rows have.
- **`PendingUpdate`'s newer fields are `#[serde(default)]`.** `load_pending`
  swallows deserialize errors and returns None, so without the default an
  existing `state.json` would be silently discarded on upgrade -- which reads to
  the user as the tray forgetting a pending update.
- **`dontWrapGApps` plus a manual `wrapProgram`.** `wrapGAppsHook4` would wrap
  both binaries and fight the existing `postFixup`; taking `gappsWrapperArgs`
  by hand gives each binary only what it needs. The daemon finds the dialog as
  a *sibling* of its own executable, which survives makeWrapper because both
  wrappers stay in `$out/bin`.

## Failure reports

A failed check or apply records an `ErrorReport` on the worker and grows two
menu entries -- "Open failure report" and "Troubleshoot with Claude" -- which
also appear as buttons on the error notification. Both write the same
deterministic Markdown to `<cache_dir>/troubleshoot.md` and open it in the
user's terminal: one in `$EDITOR`, the other as the opening prompt of a Claude
Code session cwd'd to the flake checkout. One writer, two ways to open it.

The tray menu is **contextual and exclusive**: between "Check for updates" and
"Quit" there is at most one block, and a recorded failure beats a pending
update. The consequence is deliberate -- a failed apply leaves `State::
UpdatesAvailable` so its idempotence guards can resume it, but the Apply
submenu is hidden until the next successful check clears the failure.

Things that are the way they are on purpose:

- **The report is written on click, not on failure.** It quotes `git status`,
  the branch revs and the daemon's own journal, and those are only worth having
  as of the moment someone is about to debug them. `last_error` is likewise
  in-memory only, unlike `PendingUpdate`: it quotes this boot's journal.
- **The journal comes from `INVOCATION_ID`**, falling back to `-t
  nixos-update-manager` for a bare `cargo run`. `journalctl` is deliberately
  not in the `makeWrapper` PATH, for the same reason `run0` is not: it has to
  match the running system.
- **Both quoting sections are capped** (32 KiB of error, 24 KiB of log, tails
  kept). A failed `nix build` puts its entire log into the anyhow chain *and*
  the journal, and an unbounded report is one nobody reads.
- **Claude gets the path in prose plus `--add-dir <cache_dir> -- <prompt>`**,
  not an `@` reference: `@` is CLAUDE.md import syntax, and the report lives
  outside the checkout the session is rooted in. The positional prompt (no
  `-p`) is what starts an interactive session with it already submitted, and
  the `--` is load-bearing -- `--add-dir` takes `<directories...>`, so without
  it the prompt is read as another directory and the session opens empty.
- **`editor` is a PATH-resolved string, `claudePackage` an absolute store
  path.** The editor should be whichever editor the home profile installs, not
  a second one from the store; Claude should not depend on the unit's PATH.
- With no terminal configured at all the entries are never shown rather than
  shown broken.

## Icons

The daemon borrows no freedesktop icon names at all. It ships sixteen source
SVGs of its own: eight status badges (idle, checking, up-to-date,
updates-available, applying, building, error, blocked) and eight menu glyphs
(search, apply, review, report, troubleshoot, quit, build, cancel), with
`building` rendered as 21 frames (`building-000` … `building-100`, one per
5 %) that the daemon picks between by rounding the build's fraction. Nothing
is looked up by name, so the icons survive a broken Qt or GTK platform theme:

- the tray icon goes out as an SNI **pixmap** (ARGB32, big-endian), with
  `IconName` deliberately left empty -- a host prefers the name whenever it can
  resolve one, so setting both would mean our art is never drawn;
- menu entries go out as dbusmenu **`icon-data`** (raw PNG), with `icon-name`
  empty for the same reason;
- notifications get an **absolute path** to the 64px PNG.

**The status icons share one silhouette: an arrow landing on a baseline.**
That mark is the identity and must stay in every state -- a tray icon's first
job is to say *which daemon* it belongs to, and an earlier draft that used a
plain ring as the constant element failed at exactly that (a ring plus a
checkmark is indistinguishable from any VPN or sync indicator). State is carried
by three channels layered on top:

| Channel | Values |
|---|---|
| arrowhead | stroked (settled) / solid (wants attention, or data moving) |
| baseline | solid (settled) / `4 2` dashed (busy) / gapped under the tip (blocked: the arrow cannot land) / faint track with a solid segment growing left to right (building) |
| colour | one colour per state -- cool while the daemon works (checking, building, applying), warm when it is the user's turn (decide, fix the checkout, broke) |

Two consequences worth knowing before editing the art. The baseline sits at the
same `y` in every state on purpose, so the glyph does not visibly jump when the
daemon changes state -- including across the 21 building frames. And `idle` and
`up-to-date` are deliberately the same shape, separated only by hue -- both mean
"nothing to do", and `idle` only exists until the first check runs. `error` is
still the single state that breaks the pattern: the arrow shrinks to ~70% to
make room for an exclamation, which is worth the lost size there and nowhere
else; `blocked` and `building` keep the full-size arrow and vary only the
baseline.

`icons/` holds the SVG sources -- one 24px grid, all strokes `currentColor` --
and `nix/icons.nix` rasterizes them with `resvg --stylesheet`, one colour per
argument (the states are `Status` context, the menu glyphs are `Actions`):

```nix
pkgs.nixos-update-manager-icons.override { error = "#ff0000"; }
```

The building frames come out of that same stylesheet: `building.svg` draws the
bar as a second copy of the baseline with `stroke-linecap="butt"` (a round cap
on a zero-length dash renders as a dot, so 0 % would not be empty), and each
frame's CSS sets `#progress { stroke-dasharray: <L> 100 }` with `L` the first
`16·p/100` units of the 16-unit baseline. Verified on resvg 0.48 to render
byte-identically to an explicit `h<L>` path. Lengths are absolute because resvg
does **not** honour `pathLength`; the derivation computes them in tenths, exact
for multiples of 5. The plain `building.png` is the 0 % frame, so the state has
a name without a fraction; a frame the daemon cannot load falls back to
`applying`'s pixmaps (and `blocked` to `error`'s), so an icons derivation that
predates a state still keeps the tray on our own art.

It is a **separate derivation from the daemon on purpose**. The daemon takes the
rendered tree as a runtime path (`--icon-dir`), so a recolour re-realizes one
`runCommand`; folding the store path into `nix/package.nix`'s wrapper would
put it in that derivation's `postFixup` and make every palette change recompile
the Rust crate.

The colours are also module options (`services.nixos-update-manager.icons.<state>`),
null by default so the icons package's own palette applies; `iconPackage` is
the escape hatch, and it is the one that matters while the module is enabled:
the unit always passes `--icon-dir`, so overriding `nixos-update-manager-icons`
on `package` only changes the binary's standalone default.
