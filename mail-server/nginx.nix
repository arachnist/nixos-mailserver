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

with (import ./common.nix { inherit config lib pkgs; });

let
  cfg = config.mailserver;
in
{
  config = lib.mkIf (cfg.enable && (cfg.certificateScheme == "acme" || cfg.certificateScheme == "acme-nginx")) {
    services.nginx = lib.mkIf (cfg.certificateScheme == "acme-nginx") {
      enable = true;
      virtualHosts."${cfg.fqdn}" = {
        serverName = cfg.fqdn;
        serverAliases = cfg.certificateDomains;
        forceSSL = true;
        enableACME = true;
      };
    };

    security.acme.certs."${cfg.acmeCertificateName}".reloadServices = [
      "postfix.service"
      "dovecot2.service"
    ];
  };
}
