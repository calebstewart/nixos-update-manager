# The documentation site at https://calebstew.art/nixos-update-manager.
#
# A plain callPackage derivation like the other two, reading nothing from the
# flake: `nix build .#docs` here and the Pages workflow run the same one, so CI
# cannot drift from what you preview locally.
{
  lib,
  stdenvNoCC,
  cacert,
  zola,
}:
stdenvNoCC.mkDerivation {
  pname = "nixos-update-manager-docs";
  version = "0.1.0";

  # Only docs/. The site does not depend on the crate, so a Rust change must
  # not re-realize it -- and `zola build` would otherwise see target/ and the
  # rest of the checkout in its source.
  src = lib.fileset.toSource {
    root = ../docs;
    fileset = lib.fileset.unions [
      ../docs/config.toml
      ../docs/content
      ../docs/static
      ../docs/templates
    ];
  };

  nativeBuildInputs = [ zola ];

  # Zola 0.23 builds a reqwest client up front for `load_data`, and panics if
  # it cannot load any CA certificates -- which a sandboxed build has none of.
  # This site fetches nothing; the certificates are only there so the client
  # constructs.
  SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

  buildPhase = ''
    runHook preBuild
    zola build --output-dir ./public
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    cp -r ./public $out
    runHook postInstall
  '';

  meta = {
    description = "Documentation site for nixos-update-manager";
    homepage = "https://calebstew.art/nixos-update-manager";
    license = lib.licenses.mit;
    platforms = lib.platforms.all;
  };
}
