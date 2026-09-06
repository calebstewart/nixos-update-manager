# Home-Manager module: `services.nixos-update-manager`.
#
# Takes `self` so the package defaults can point at this flake's own outputs
# without requiring the consumer to apply the overlay. flake.nix wraps the
# result with a `_file` so the options still carry a source position.
{ self }:
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.services.nixos-update-manager;
  system = pkgs.stdenv.hostPlatform.system;
  ownPackages = self.packages.${system};

  # Null means "the icon package's own colour for that state". The stewardship
  # of the palette stays with the icons derivation; this only lets a host
  # recolour one state without respelling the rest.
  mkIconColor =
    when:
    lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "#f38ba8";
      description = ''
        Colour (`#rrggbb`) of the icon shown ${when}. Null keeps the icon
        package's default.
      '';
    };

  iconOverrides = lib.filterAttrs (_: v: v != null) cfg.icons;
in
{
  options.services.nixos-update-manager = {
    enable = lib.mkEnableOption "the NixOS update-manager tray daemon";

    package = lib.mkOption {
      type = lib.types.package;
      default = ownPackages.nixos-update-manager;
      defaultText = lib.literalExpression "nixos-update-manager.packages.\${system}.nixos-update-manager";
      description = "The update-manager package to run.";
    };

    # The hues are chosen so the temperature says whose turn it is: cool while
    # the daemon is working (checking, building, applying), warm when it is
    # the user's (an update to decide on, a checkout to fix, something broke).
    # Overriding one keeps the rest at their defaults.
    icons = {
      idle = mkIconColor "when no check has run yet";
      checking = mkIconColor "while checking for updates";
      upToDate = mkIconColor "when up to date";
      updatesAvailable = mkIconColor "when an update is waiting to be built or applied";
      applying = mkIconColor "while applying updates";
      building = mkIconColor "while building the update";
      error = mkIconColor "when the last operation failed";
      blocked = mkIconColor "when uncommitted changes in the checkout block an update";

      # The menu glyphs are actions, so they take no meaning from their hue and
      # share one neutral colour.
      menu = mkIconColor "on the tray menu's own entries";
    };

    iconPackage = lib.mkOption {
      type = lib.types.package;
      default = ownPackages.nixos-update-manager-icons.override iconOverrides;
      defaultText = lib.literalExpression "nixos-update-manager.packages.\${system}.nixos-update-manager-icons.override <the non-null icons.*>";
      description = ''
        Rendered icon theme the daemon draws its tray and notification icons
        from. The daemon is pointed at it with `--icon-dir`, so this -- not
        {option}`package` -- is the icon knob while the module is in charge;
        overriding `nixos-update-manager-icons` on {option}`package` only
        affects the binary's own default, which the unit overrides.
      '';
    };

    flakePath = lib.mkOption {
      type = lib.types.str;
      example = "/home/alice/nixos";
      description = ''
        Git checkout of the flake to update and merge back into. It must
        declare `nixosConfigurations.<hostname>` and
        `homeConfigurations."<user>@<hostname>"`.
      '';
    };

    branch = lib.mkOption {
      type = lib.types.str;
      default = "nixos-update";
      description = ''
        Branch the update check builds on, in a worktree of its own. A
        successful apply fast-forwards `main` to it.
      '';
    };

    # When something fails, the daemon writes a report to its cache directory
    # and opens it in a terminal of its own -- in the editor, or as the opening
    # prompt of a Claude Code session rooted in the flake checkout. These are
    # what it opens it with.
    terminal = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      example = lib.literalExpression "pkgs.alacritty";
      description = ''
        Terminal emulator the troubleshooting entries open in. With none, the
        daemon falls back to `$TERMINAL`, and without that the entries are not
        offered at all rather than offered broken.
      '';
    };

    terminalArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "-e" ];
      description = ''
        Arguments that make {option}`terminal` run a command, placed before the
        command itself. Empty for a terminal that takes it positionally.
      '';
    };

    editor = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "nvim";
      description = ''
        Editor the failure report opens in. Resolved from the daemon's PATH
        rather than the store on purpose, so it picks up the editor the home
        profile installs instead of a second one. Null lets the daemon fall
        back to `$EDITOR`, then `nvim`.
      '';
    };

    claudePackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      example = lib.literalExpression "pkgs.claude-code";
      description = ''
        Claude Code used by the "Troubleshoot with Claude" entry. Passed by
        absolute path, so unlike {option}`editor` it does not depend on the
        unit's PATH. Null resolves `claude` from PATH instead.
      '';
    };

    checkInterval = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "([0-9]+(s|m|h|d))+");
      default = null;
      example = "6h";
      description = ''
        How often the daemon checks for updates on its own, as a time span
        ("30m", "6h", "1h30m", "1d"). Null means only when asked from the
        tray. A check only evaluates -- it downloads and builds nothing
        unless {option}`autoBuild` is set -- and the daemon never starts one
        while a build or apply is running or the checkout has local changes.
      '';
    };

    autoBuild = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Build an update as soon as a scheduled check finds one, instead of
        waiting for "Build update" in the tray or the review dialog. Applying
        is never automatic.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && pkgs.stdenv.hostPlatform.isLinux) {
    assertions = [
      {
        assertion = cfg.flakePath != "";
        message = "services.nixos-update-manager.flakePath must name the flake checkout to update.";
      }
    ];

    home.packages = [ cfg.package ];

    systemd.user.services.nixos-update-manager = {
      Unit = {
        Description = "NixOS update-manager tray daemon";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };

      Service = {
        Type = "simple";
        # escapeShellArgs rather than a plain join: terminalArgs is a
        # user-supplied list, and systemd honours the single quotes it emits.
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe cfg.package)
            "--flake"
            cfg.flakePath
            "--branch"
            cfg.branch
            "--icon-dir"
            "${cfg.iconPackage}/share/icons"
          ]
          ++ lib.optionals (cfg.terminal != null) [
            "--terminal"
            (lib.getExe cfg.terminal)
          ]
          # Always pass at least one, or the daemon's own "-e" default applies.
          # An empty argument is how "this terminal needs none" is spelled; the
          # daemon drops it.
          ++ lib.concatMap (arg: [
            "--terminal-arg"
            arg
          ]) (if cfg.terminalArgs == [ ] then [ "" ] else cfg.terminalArgs)
          ++ lib.optionals (cfg.editor != null) [
            "--editor"
            cfg.editor
          ]
          ++ lib.optionals (cfg.claudePackage != null) [
            "--claude"
            (lib.getExe cfg.claudePackage)
          ]
          ++ lib.optionals (cfg.checkInterval != null) [
            "--check-interval"
            cfg.checkInterval
          ]
          ++ lib.optional cfg.autoBuild "--auto-build"
        );
        Restart = "on-failure";
        RestartSec = 5;
      };

      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
