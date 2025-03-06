{ config, lib, pkgs, ... }:
with lib;
let
  ms = config.mailserver;
  cfg = ms.autoconfig;

  # none of the available parameters are configurable in
  # simple-mailserver so these templates aren't configurable either
  incomingServer = enable: port: socketType: optionalString enable ''
    <incomingServer type="imap">
      <hostname>${ms.fqdn}</hostname>
      <port>${builtins.toString port}</port>
      <socketType>${socketType}</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
    </incomingServer>
  '';

  # we currently only support STARTTLS for outgoing servers
  outgoingServer = port: ''
    <outgoingServer type="smtp">
      <hostname>${ms.fqdn}</hostname>
      <port>${builtins.toString port}</port>
      <socketType>STARTTLS</socketType>
      <authentication>password-cleartext</authentication>
      <username>%EMAILADDRESS%</username>
    </outgoingServer>
  '';
in {
  mailserver.autoconfig.webRoot = pkgs.substituteAll ({
    name = "config-v1.1.xml";
    dir = "mail";
    src = cfg.templateFile;
  } // {
    hostname = ms.fqdn;
    inherit (cfg)
      emailProviderId displayName displayShortName extraEmailProvider;
    imapSslServer = incomingServer ms.enableImapSsl 993 "SSL";
    imapServer = incomingServer ms.enableImapSsl 143 "STARTTLS";
    pop3SslServer = incomingServer ms.enablePop3Ssl 995 "SSL";
    pop3Server = incomingServer ms.enablePop3 110 "STARTTLS";
    smtpServer = outgoingServer 25;
    submissionServer = outgoingServer 587;
    domains = concatMapStringsSep
      "\n    "
      (x: "<domain>${x}</domain>")
      cfg.domains;
  });
}
