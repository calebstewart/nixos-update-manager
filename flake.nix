{
  description = "Tray daemon that checks, builds and applies NixOS + Home-Manager flake updates";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      # The daemon drives switch-to-configuration and run0, so Linux only. No
      # flake-utils: two systems is short enough to spell out.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The icons are a separate derivation from the daemon on purpose. The
      # daemon takes the rendered tree by path at runtime (--icon-dir), so a
      # recolour re-realizes one runCommand instead of recompiling the crate.
      mkPackages = pkgs: rec {
        nixos-update-manager-icons = pkgs.callPackage ./nix/icons.nix { };
        nixos-update-manager = pkgs.callPackage ./nix/package.nix {
          inherit nixos-update-manager-icons;
        };
      };

      # The documentation site. Deliberately outside mkPackages: the overlay
      # adds what a consumer installs, and nobody installs a website.
      mkDocs = pkgs: pkgs.callPackage ./nix/docs.nix { };

      formatter =
        pkgs:
        pkgs.nixfmt-tree.override {
          runtimeInputs = [ pkgs.rustfmt ];
          settings.formatter.rustfmt = {
            command = "rustfmt";
            options = [
              "--edition"
              "2021"
            ];
            includes = [ "*.rs" ];
          };
        };

      # The module is a function of `self` (it needs its own packages for the
      # defaults), and a function has no source position. The wrapper gives it
      # one, so a consumer's option documentation credits these options to this
      # file rather than to whichever file imported the module.
      homeModule = {
        _file = "${self}/nix/hm-module.nix";
        imports = [ (import ./nix/hm-module.nix { inherit self; }) ];
      };
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          packages = mkPackages pkgs;
        in
        packages
        // {
          default = packages.nixos-update-manager;
          docs = mkDocs pkgs;
        }
      );

      overlays.default = final: _prev: mkPackages final;

      homeModules.default = homeModule;
      # The older spelling, for consumers that still look for it.
      homeManagerModules.default = homeModule;

      formatter = forAllSystems formatter;

      checks = forAllSystems (
        pkgs:
        mkPackages pkgs
        // {
          # A broken template or a dead `@/` link fails the build, so the site
          # cannot go stale unnoticed between pushes to it.
          docs = mkDocs pkgs;

          # treefmt --ci fails on any file its formatters would change, so
          # `nix flake check` catches what `nix fmt` would have fixed. The tree
          # root is explicit: there is no git checkout in the sandbox, and
          # without one treefmt falls back to the directory holding its config
          # file -- which is /nix/store, all of it.
          formatting =
            pkgs.runCommand "nixos-update-manager-formatting"
              {
                nativeBuildInputs = [ (formatter pkgs) ];
              }
              ''
                cp -r ${self} src
                chmod -R u+w src
                cd src
                treefmt --ci --walk filesystem --tree-root "$PWD"
                touch $out
              '';
        }
      );

      devShells = forAllSystems (
        pkgs:
        let
          packages = mkPackages pkgs;
        in
        {
          default = pkgs.mkShell {
            name = "nixos-update-manager";

            inputsFrom = [ packages.nixos-update-manager ];

            packages = with pkgs; [
              cargo
              rustc
              clippy
              rustfmt
              rust-analyzer
              resvg
              # `zola serve` in docs/ previews the site at 127.0.0.1:1111.
              zola
              (formatter pkgs)
            ];

            # `cargo run` has no $out/libexec to find the privileged helper in,
            # and no wrapper to hand it the icons; point it at the store
            # copies so a dev build behaves like the installed one.
            NIXOS_UPDATE_APPLY_HELPER = "${packages.nixos-update-manager}/libexec/nixos-update-apply-system";
            NIXOS_UPDATE_ICON_DIR = "${packages.nixos-update-manager-icons}/share/icons";
          };
        }
      );
    };
}
