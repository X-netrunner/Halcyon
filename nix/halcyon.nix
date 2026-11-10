# The rice itself (Hyprland Lua config, the Quickshell island, scripts, systemd units) with the helpers in bin/, as
# install.sh lays it out in ~/.config/Halcyon. The Home Manager module copies it there.
{ lib, stdenvNoCC, src, helpers }:

stdenvNoCC.mkDerivation {
  pname = "halcyon";
  version = "0-unstable";
  src = lib.cleanSourceWith {
    inherit src;
    filter = path: type:
      let base = baseNameOf (toString path); in
      !(builtins.elem base [ "target" ".git" ".github" "result" "nix" "flake.nix" "flake.lock" ]);
  };
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/halcyon/bin
    cp -r . $out/share/halcyon/
    for b in ${helpers}/bin/*; do ln -s "$b" "$out/share/halcyon/bin/$(basename "$b")"; done
    runHook postInstall
  '';
  meta = {
    description = "Halcyon: a Hyprland desktop built around one floating island";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
  };
}
