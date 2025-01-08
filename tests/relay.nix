# This tests is used to test features requiring several mail domains.

{ lib, pkgs ? import <nixpkgs> { }, ... }:

let
  hashPassword = password: pkgs.runCommand
    "password-${password}-hashed"
    { buildInputs = [ pkgs.mkpasswd ]; inherit password; }
    ''
      mkpasswd -sm bcrypt <<<"$password" > $out
    '';

  password = pkgs.writeText "password" "password";

  domainGenerator = domain: {
    imports = [ ../default.nix ];
    virtualisation.memorySize = 1024;
    mailserver = {
      enable = true;
      fqdn = "mail.${domain}";
      domains = [ domain ];
      localDnsResolver = false;
      loginAccounts = {
        "user@${domain}" = {
          hashedPasswordFile = hashPassword "password";
        };
      };
      enableImap = true;
      enableImapSsl = true;
    };
    services = {
      dnsmasq = {
        enable = true;
        settings.mx-host = [ "domain1.com,domain1,10" "domain2.com,domain2,10" ];
      };
      # disable rspamd because of graylisting
      postfix.config.smtpd_milters = lib.mkForce [ ];
      rspamd.enable = lib.mkForce false;
      redis.servers.rspamd.enable = false;
    };
    systemd.services.postfix.requires = lib.mkForce [ "postfix-setup.service" ];
  };

in

pkgs.nixosTest {
  name = "relay";
  nodes = {
    domain1 = {
      imports = [
        ../default.nix
        (domainGenerator "domain1.com")
      ];
      mailserver.relayDomains = [ "replay.domain1.com" ];
      # ip of itself
      services.postfix.networks = [ "[2001:db8:1::1]/128" ];
    };
    domain2 = domainGenerator "domain2.com";
    client = { pkgs, ... }: {
      environment.systemPackages = [
        (pkgs.writeScriptBin "mail-check" ''
          ${pkgs.python3}/bin/python ${../scripts/mail-check.py} $@
        '')
      ];
    };
  };
  testScript = ''
    start_all()

    domain1.wait_for_unit("multi-user.target")
    domain2.wait_for_unit("multi-user.target")

    # user@domain1.com sends a mail to user@domain2.com
    client.succeed(
        "mail-check send-and-read --smtp-port 25 --smtp-starttls --smtp-host domain1 --from-addr user@relay.domain1.com --imap-host domain2 --to-addr user@domain2.com --dst-password-file ${password} --ignore-dkim-spf"
    )
  '';
}
