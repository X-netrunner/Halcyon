# NixOS module: what install.sh installs system-wide on Arch (Hyprland, Quickshell, the island's tools, audio, Bluetooth,
# network, power, fonts). Use it together with the Home Manager module (nix/home.nix), which puts the rice in place.
self:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.halcyon;
  python = pkgs.python3.withPackages (ps: [ ps.pillow ps.pygobject3 ]);
in
{
  options.programs.halcyon = {
    enable = lib.mkEnableOption "the Halcyon desktop (Hyprland + the Quickshell island)";
    ai.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Run Ollama locally for >ask, >do, notes and the ClamAV fixes (nothing leaves the machine). Pull a model afterwards: ollama pull qwen2.5:3b-instruct";
    };
    clamav.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "ClamAV with its signature updater, for the Security center's ClamAV page.";
    };
    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "More packages for the desktop (your browser, file manager, editor).";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.hyprland.enable = true;          # also sets up xdg-desktop-portal-hyprland
    programs.fish.enable = true;
    programs.dconf.enable = true;
    programs.gamemode.enable = true;

    environment.systemPackages = (with pkgs; [
      quickshell hypridle hyprlock hyprsunset hyprpicker
      xdg-desktop-portal-gtk kdePackages.polkit-kde-agent-1
      qt6Packages.qt6ct kdePackages.qtstyleplugin-kvantum kdePackages.kservice kdePackages.qtwayland kdePackages.qtsvg
      kdePackages.qt5compat kdePackages.qtmultimedia
      imagemagick cava btop fish starship poppler-utils fd ripgrep fzf grim slurp wl-clipboard cliphist fuzzel
      tesseract dmidecode util-linux lsof jq zenity libnotify qrencode wtype brightnessctl playerctl pavucontrol
      networkmanagerapplet wlogout bemoji foot git curl pciutils procps rsync ffmpegthumbnailer
      adwaita-icon-theme papirus-icon-theme
    ]) ++ [ python self.packages.${pkgs.stdenv.hostPlatform.system}.helpers ]
      ++ lib.optional cfg.clamav.enable pkgs.clamav
      ++ cfg.extraPackages;

    fonts.packages = with pkgs; [ inter nerd-fonts.jetbrains-mono noto-fonts noto-fonts-color-emoji ];

    services.pipewire = {
      enable = lib.mkDefault true;
      alsa.enable = lib.mkDefault true;
      pulse.enable = lib.mkDefault true;
      wireplumber.enable = lib.mkDefault true;
    };
    hardware.bluetooth.enable = lib.mkDefault true;
    services.blueman.enable = lib.mkDefault true;
    networking.networkmanager.enable = lib.mkDefault true;
    services.upower.enable = lib.mkDefault true;
    services.power-profiles-daemon.enable = lib.mkDefault true;
    services.udisks2.enable = lib.mkDefault true;
    services.gvfs.enable = lib.mkDefault true;
    security.polkit.enable = true;
    # the lock screen checks your password through PAM (quickshell/island/pam/password.conf)
    security.pam.services.quickshell = { };

    services.ollama = lib.mkIf cfg.ai.enable {
      enable = true;
      host = "127.0.0.1";                     # local only: nothing leaves the machine
    };
    services.clamav = lib.mkIf cfg.clamav.enable {
      updater.enable = true;
      daemon.enable = false;                  # the Security center runs clamscan on demand
    };
  };
}
