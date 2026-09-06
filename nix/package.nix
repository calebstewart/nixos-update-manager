{
  lib,
  rustPlatform,
  pkg-config,
  makeWrapper,
  wrapGAppsHook4,
  dbus,
  glib,
  gtk4,
  libadwaita,
  git,
  nix,
  nixos-update-manager-icons,
}:
rustPlatform.buildRustPackage {
  pname = "nixos-update-manager";
  version = "0.1.0";

  # An explicit file set rather than lib.cleanSource: the latter keeps target/,
  # so every stray local build ends up copied into the store.
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../src
      ../apply-system.sh
    ];
  };
  cargoLock.lockFile = ../Cargo.lock;

  nativeBuildInputs = [
    pkg-config
    makeWrapper
    # The review dialog is a GTK4 app and needs GSettings schemas and the icon
    # cache resolved at runtime; without this it starts but logs
    # `g_settings_schema_source_lookup: assertion 'source != NULL' failed`.
    wrapGAppsHook4
  ];
  # gtk4/libadwaita are the dialog's, not the daemon's. Cargo dependencies are
  # per *package*, so both binaries build against them even though only
  # nixos-update-review links the result.
  buildInputs = [
    dbus
    glib
    gtk4
    libadwaita
  ];

  postInstall = ''
    install -Dm555 apply-system.sh $out/libexec/nixos-update-apply-system
    substituteInPlace $out/libexec/nixos-update-apply-system \
      --replace-fail "@nix@" "${nix}"
  '';

  # git and nix are subprocesses of the daemon. run0 (the privilege path) is
  # deliberately not wrapped in: it must talk to the running system's PID 1,
  # so the system's own copy from the base PATH is the right one.
  #
  # The icons are set-default rather than set: this is only the fallback
  # palette, and the home-manager module passes a recoloured set on the command
  # line. Keeping them out of the build inputs proper is the point -- a palette
  # change must not recompile the crate.
  # wrapGAppsHook4 would otherwise wrap both binaries and fight the manual
  # wrapProgram below. Taking its arguments by hand instead lets each binary
  # get only what it needs: the daemon is not a GTK app, and the dialog does
  # not run git or nix.
  dontWrapGApps = true;

  postFixup = ''
    wrapProgram $out/bin/nixos-update-manager \
      --prefix PATH : ${
        lib.makeBinPath [
          git
          nix
        ]
      } \
      --set-default NIXOS_UPDATE_ICON_DIR ${nixos-update-manager-icons}/share/icons

    # The daemon finds the dialog as a sibling of its own executable, and
    # makeWrapper keeps both in $out/bin -- so this stays the wrapper, and the
    # GTK environment survives the spawn.
    wrapProgram $out/bin/nixos-update-review "''${gappsWrapperArgs[@]}"
  '';

  meta = {
    description = "Tray daemon that checks, builds and applies NixOS + Home-Manager flake updates";
    homepage = "https://github.com/calebstewart/nixos-update-manager";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "nixos-update-manager";
  };
}
