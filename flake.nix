{
  # Halcyon on NixOS: the Rust helpers and the rice as packages, a NixOS module (Hyprland, Quickshell, the services and
  # fonts the island needs) and a Home Manager module (puts the rice into ~/.config/Halcyon and starts the user services).
  # How to use it: docs/install-nix.md. install.sh is not used on NixOS.
  description = "Halcyon: a Hyprland desktop built around one floating island";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: rec {
        helpers = pkgs.callPackage ./nix/helpers.nix { src = self; };
        halcyon = pkgs.callPackage ./nix/halcyon.nix { src = self; inherit helpers; };
        default = halcyon;
      });

      nixosModules.default = import ./nix/nixos.nix self;
      homeManagerModules.default = import ./nix/home.nix self;

      # `nix flake check` evaluates both modules against a minimal system, so a typo in an option fails here
      checks = forAll (pkgs: {
        nixos-module = (nixpkgs.lib.nixosSystem {
          inherit (pkgs.stdenv.hostPlatform) system;
          modules = [
            self.nixosModules.default
            {
              programs.halcyon.enable = true;
              fileSystems."/" = { device = "/dev/null"; fsType = "ext4"; };
              boot.loader.grub.enable = false;
              system.stateVersion = "26.05";
            }
          ];
        }).config.system.build.toplevel;
      });
    };
}
