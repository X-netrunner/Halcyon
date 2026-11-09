# Installing on NixOS

On NixOS, Halcyon is installed with the flake in the repository, not with `install.sh` (which stops on NixOS and points here).
The flake has:

| Output | What it is |
|---|---|
| `packages.<system>.helpers` | The Rust helpers (hx, hal, hgl, power-manager, touchpad-gestures, ...), the whole Cargo workspace |
| `packages.<system>.halcyon` (default) | The rice, laid out as in `~/.config/Halcyon`, with the helpers in `bin/` |
| `nixosModules.default` | System side: Hyprland, Quickshell, the island's tools, PipeWire, Bluetooth, NetworkManager, power, fonts, PAM for the lock screen |
| `homeManagerModules.default` | User side: copies the rice into `~/.config/Halcyon` (your files are kept), `~/.config/hypr/hyprland.lua`, the user services |

Back to the [README](../README.md).

## Set it up

In your system flake:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    halcyon.url = "github:X-netrunner/Halcyon";
    halcyon.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, home-manager, halcyon, ... }: {
    nixosConfigurations.mymachine = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        halcyon.nixosModules.default
        { programs.halcyon.enable = true; }
        home-manager.nixosModules.home-manager
        {
          home-manager.users.me = {
            imports = [ halcyon.homeManagerModules.default ];
            programs.halcyon.enable = true;
            home.stateVersion = "26.05";
          };
        }
      ];
    };
  };
}
```

Then `sudo nixos-rebuild switch`, log out, and pick the Hyprland session.

## Options

NixOS module (`programs.halcyon`):

- `enable`: the desktop (Hyprland, Quickshell, tools, services, fonts).
- `ai.enable` (default false): Ollama, listening on 127.0.0.1 only, for `>ask`, `>do`, notes and the ClamAV fixes. Pull a model
  afterwards: `ollama pull qwen2.5:3b-instruct`.
- `clamav.enable` (default false): ClamAV with its signature updater, for the Security center's ClamAV page.
- `extraPackages`: your browser, file manager, editor, and so on.

Home Manager module (`programs.halcyon`): `enable`, and `package` to use another build.

## How it differs from install.sh

- **The rice is copied, not linked.** Halcyon writes into `~/.config/Halcyon` (the colour scheme from the wallpaper, settings,
  `hypr-user.lua`), so it cannot live in the read-only Nix store. Each activation copies the new version over it and keeps
  `hypr-user.lua`, `scheme/current.lua`, `gamemode.conf` and `ai-advisor.conf`, like `install.sh` does.
- **The user services** (power manager, touchpad gestures, reminders, notes, "explain why it failed") are defined in the Home
  Manager module with Nix store paths; the reminder timers are switched on by the island while a reminder waits, as on Arch.
- **Not covered on NixOS:** sysmode and the root helpers (`halcyon-tune`, the safety check), ai-firewall, ai-antivirus, the
  tty1 lock-screen login, Plymouth, and `update.sh` (update with `nix flake update` and a rebuild). These change the system
  imperatively, which NixOS does differently. Configure the equivalents in your NixOS configuration if you need them.

## Tested

`nix flake check` passes; it also evaluates a full NixOS system with the module on. In a `nixos/nix` container, all 11 Rust
helpers, the rice package and a Home Manager generation that uses the module build. The activation's copy step (rsync with the
kept files) was checked on its own: your `hypr-user.lua` and `scheme/current.lua` stay, and the copied files are writable.
A full Home Manager activation and a real NixOS desktop session have not been tried yet.
