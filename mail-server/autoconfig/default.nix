{ config, lib, pkgs, ... }:
with lib;
let
  ms = config.mailserver;
  cfg = ms.autoconfig;
in
{
  imports = [ ./webroot.nix ];

  options.mailserver.autoconfig = mkOption {
    description = ''
      Generate a simple static Mozilla-style autoconfig.

      See
      https://developer.mozilla.org/en-US/docs/Mozilla/Thunderbird/Autoconfiguration
      for further information on the file format.

      Note that for each domain in `domains`, this will generate a
      nginx `virtualHost` for the `autoconfig` subdomain of that
      domain.

      In order for autoconfig to work, those domains must be
      accessible (i.e. have DNS records).
    '';
    type = types.submodule {
      options = {
        enable = mkEnableOption "Mozilla-style autoconfig (requires nginx)";

        emailProviderId = mkOption {
          type = types.str;
          example = "example.com";
          default = ms.fqdn;
          defaultText = "config.mailserver.fqdn";
          description = ''
            An ID for the email provider.
          '';
        };

        domains = mkOption {
          type = types.listOf types.str;
          example = [ "example.com" "example.net" ];
          default = ms.domains;
          defaultText = "config.mailserver.domains";
          description = ''
            A list of domains for which to enable autoconfig.
          '';
        };

        displayName = mkOption {
          type = types.str;
          example = "Joe's Email Provider";
          default = cfg.emailProviderId;
          defaultText = "config.mailserver.autoconfig.id";
          description = ''
            A user-readable name for the email provider.
          '';
        };

        displayShortName = mkOption {
          type = types.str;
          example = "JoeMail";
          default = cfg.displayName;
          defaultText = "config.mailserver.autoconfig.displayName";
          description = ''
            A "short" user-readable name for the email provider.
          '';
        };

        templateFile = mkOption {
          type = types.path;
          example = "/path/to/template.xml";
          default = ./template.xml;
          description = ''
            A path to a template file to use.
          '';
        };

        extraEmailProvider = mkOption {
          type = types.lines;
          default = "";
          description = ''
            Extra XML to be embedded at the end of the <emailProvider> element.
          '';
        };

        webRoot = mkOption {
          type = types.path;
          visible = false;
        };
      };
    };
  };

  config = mkIf config.mailserver.autoconfig.enable {
    services.nginx.enable = true;
    services.nginx.virtualHosts = mkMerge (map (domain: {
      "autoconfig.${domain}".root = cfg.webRoot;
    }) cfg.domains);
  };
}
