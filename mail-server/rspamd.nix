#  nixos-mailserver: a simple mail server
#  Copyright (C) 2016-2018  Robin Raymond
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program. If not, see <http://www.gnu.org/licenses/>

{ config, pkgs, lib, ... }:

let
  cfg = config.mailserver;

  postfixCfg = config.services.postfix;
  rspamdCfg = config.services.rspamd;
  rspamdSocket = "rspamd.service";
in
{
  config = with cfg; lib.mkIf enable {
    environment.systemPackages = lib.mkBefore [
      (pkgs.runCommand "rspamc-wrapped" {
        nativeBuildInputs = with pkgs; [ makeWrapper ];
       }''
        makeWrapper ${pkgs.rspamd}/bin/rspamc $out/bin/rspamc \
          --add-flags "-h /var/run/rspamd/worker-controller.sock"
      '')
    ];

    services.rspamd = {
      enable = true;
      inherit debug;
      locals = {
          "milter_headers.conf" = { text = ''
              extended_spam_headers = true;
          ''; };
          "redis.conf" = { text = ''
              servers = "${cfg.redis.address}:${toString cfg.redis.port}";
          '' + (lib.optionalString (cfg.redis.password != null) ''
              password = "${cfg.redis.password}";
          ''); };
          "classifier-bayes.conf" = { text = ''
              cache {
                backend = "redis";
              }
          ''; };
          "antivirus.conf" = lib.mkIf cfg.virusScanning { text = ''
              clamav {
                action = "reject";
                symbol = "CLAM_VIRUS";
                type = "clamav";
                log_clean = true;
                servers = "/run/clamav/clamd.ctl";
                scan_mime_parts = false; # scan mail as a whole unit, not parts. seems to be needed to work at all
              }
          ''; };
          "dkim_signing.conf" = { text = ''
              # Disable outbound email signing, we use opendkim for this
              enabled = false;
          ''; };
          "dmarc.conf" = { text = ''
              ${lib.optionalString cfg.dmarcReporting.enable ''
              reporting {
                enabled = true;
                email = "${cfg.dmarcReporting.email}";
                domain = "${cfg.dmarcReporting.domain}";
                org_name = "${cfg.dmarcReporting.organizationName}";
                from_name = "${cfg.dmarcReporting.fromName}";
                msgid_from = "dmarc-rua";
              }''}
          ''; };
      };

      workers.rspamd_proxy = {
        type = "rspamd_proxy";
        bindSockets = [{
          socket = "/run/rspamd/rspamd-milter.sock";
          mode = "0664";
        }];
        count = 1; # Do not spawn too many processes of this type
        extraConfig = ''
          milter = yes; # Enable milter mode
          timeout = 120s; # Needed for Milter usually

          upstream "local" {
            default = yes; # Self-scan upstreams are always default
            self_scan = yes; # Enable self-scan
          }
        '';
      };
      workers.controller = {
        type = "controller";
        count = 1;
        bindSockets = [{
          socket = "/run/rspamd/worker-controller.sock";
          mode = "0666";
        }];
        includes = [];
        extraConfig = ''
          static_dir = "''${WWWDIR}"; # Serve the web UI static assets
        '';
      };

    };

    services.redis.servers.rspamd = {
      enable = lib.mkDefault true;
      port = lib.mkDefault 6380;
    };

    systemd.services.rspamd = {
      requires = [ "redis-rspamd.service" ] ++ (lib.optional cfg.virusScanning "clamav-daemon.service");
      after = [ "redis-rspamd.service" ] ++ (lib.optional cfg.virusScanning "clamav-daemon.service");
    };

    systemd.services.rspamd-dmarc-reporter = lib.optionalAttrs (cfg.dmarcReporting.enable) {
      # Explicitly select yesterday's date to work around broken
      # default behaviour when called without a date.
      # https://github.com/rspamd/rspamd/issues/4062
      script = ''
        ${pkgs.rspamd}/bin/rspamadm dmarc_report $(date -d "yesterday" "+%Y%m%d")
      '';
      serviceConfig = {
        User = "${config.services.rspamd.user}";
        Group = "${config.services.rspamd.group}";

        AmbientCapabilities = [];
        CapabilityBoundingSet = "";
        DevicePolicy = "closed";
        IPAddressAllow = "localhost";
        LockPersonality = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateMounts = true;
        PrivateTmp = true;
        PrivateUsers = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        UMask = "0077";
      };
    };

    systemd.timers.rspamd-dmarc-reporter = lib.optionalAttrs (cfg.dmarcReporting.enable) {
      description = "Daily delivery of aggregated DMARC reports";
      wantedBy = [
        "timers.target"
      ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = 86400;
        FixedRandomDelay = true;
      };
    };

    systemd.services.postfix = {
      after = [ rspamdSocket ];
      requires = [ rspamdSocket ];
    };

    users.extraUsers.${postfixCfg.user}.extraGroups = [ rspamdCfg.group ];
  };
}

