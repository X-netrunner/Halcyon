# Home Manager module: what install.sh does for your user on Arch. The rice is copied (not linked) into ~/.config/Halcyon,
# because Halcyon writes there (the colour scheme from the wallpaper, your settings, hypr-user.lua). Your own files are
# kept, exactly as install.sh keeps them. Hyprland loads it through ~/.config/hypr/hyprland.lua.
self:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.halcyon;
  rice = "${cfg.package}/share/halcyon";
  python = pkgs.python3.withPackages (ps: [ ps.pillow ps.pygobject3 ]);
  # the same hardening the units in systemd/ have
  hardening = {
    LockPersonality = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
  };
  explain = "halcyon-explain@%n.service";
in
{
  options.programs.halcyon = {
    enable = lib.mkEnableOption "Halcyon for this user (the rice in ~/.config/Halcyon and its user services)";
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.halcyon;
      defaultText = lib.literalExpression "halcyon.packages.\${system}.halcyon";
      description = "The Halcyon package to install.";
    };
  };

  config = lib.mkIf cfg.enable {
    # copy the rice, keeping what is yours (install.sh keeps the same files)
    home.activation.halcyon = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run mkdir -p "$HOME/.config/Halcyon"
      run ${pkgs.rsync}/bin/rsync -a --chmod=u+w \
        --exclude hypr-user.lua --exclude scheme/current.lua --exclude gamemode.conf --exclude ai-advisor.conf \
        ${rice}/ "$HOME/.config/Halcyon/"
      if [ ! -e "$HOME/.config/Halcyon/hypr-user.lua" ]; then
        run install -m644 ${rice}/hypr-user.lua "$HOME/.config/Halcyon/hypr-user.lua"
      fi
    '';

    xdg.configFile."hypr/hyprland.lua".text = ''
      -- Halcyon: loads the whole rice from ~/.config/Halcyon (written by the Halcyon Home Manager module)
      dofile(os.getenv("HOME") .. "/.config/Halcyon/hyprland.lua")
    '';

    systemd.user.services = {
      power-manager = {
        Unit = { Description = "Halcyon Auto power manager (load / battery / heat aware)"; OnFailure = explain; };
        Service = hardening // { ExecStart = "%h/.config/Halcyon/bin/power-manager"; Restart = "on-failure"; RestartSec = 5; Nice = 10; };
      };
      touchpad-gestures = {
        Unit = {
          Description = "Halcyon touchpad edge gestures (volume / brightness / track skip)";
          After = [ "graphical-session.target" ];
          StartLimitIntervalSec = 60;
          StartLimitBurst = 5;
          OnFailure = explain;
        };
        Service = hardening // {
          ExecStart = "%h/.config/Halcyon/bin/touchpad-gestures";
          Restart = "on-failure";
          RestartSec = 3;
          RestartPreventExitStatus = 78;
          Environment = "PATH=/run/current-system/sw/bin:/etc/profiles/per-user/%u/bin";
        };
      };
      halcyon-remind = {
        Unit = { Description = "Halcyon: reminders to back up / run the safety check"; OnFailure = explain; };
        Service = hardening // { Type = "oneshot"; ExecStart = "%h/.config/Halcyon/scripts/remind.sh check"; NoNewPrivileges = true; };
      };
      halcyon-notes-due = {
        Unit = { Description = "Halcyon: notify about notes (tasks) whose time has come"; OnFailure = explain; };
        Service = hardening // {
          Type = "oneshot";
          Nice = 10;
          ExecStart = "${python}/bin/python3 %h/.config/Halcyon/scripts/halcyon-notes.py remind-check";
          NoNewPrivileges = true;
        };
      };
      "halcyon-explain@" = {
        Unit.Description = "Halcyon: explain why %i failed (local AI)";
        Service = hardening // {
          Type = "oneshot";
          ExecStart = "${python}/bin/python3 %h/.config/Halcyon/scripts/halcyon-ai.py explain unit %i --notify --if-new";
          Nice = 10;
          TimeoutStartSec = 180;
          NoNewPrivileges = true;
        };
      };
    };
    # the island switches these on only while a reminder is waiting (as on Arch), so they are not enabled here
    systemd.user.timers = {
      halcyon-remind = {
        Unit.Description = "Halcyon: look once a day whether a backup / safety check reminder is due";
        Timer = { OnStartupSec = "5min"; OnCalendar = "*-*-* 10:00:00"; Persistent = true; };
      };
      halcyon-notes-due = {
        Unit.Description = "Halcyon: once a minute, look for tasks in Notes whose reminder time has come";
        Timer = { OnCalendar = "minutely"; AccuracySec = "15s"; };
      };
    };
  };
}
