{ config, lib, pkgs, ... }:
{
  assertions = lib.optionals config.mailserver.ldap.enable [
    {
      assertion = config.mailserver.loginAccounts == {};
      message = "When the LDAP support is enable (mailserver.ldap.enable = true), it is not possible to define mailserver.loginAccounts";
    }
    {
      assertion = config.mailserver.extraVirtualAliases == {};
      message = "When the LDAP support is enable (mailserver.ldap.enable = true), it is not possible to define mailserver.extraVirtualAliases";
    }
    {
      assertion = config.mailserver.forwards == {};
      message = "When the LDAP support is enable (mailserver.ldap.enable = true), it is not possible to define mailserver.forwards";
    }
  ] ++ lib.optionals (config.mailserver.certificateScheme != "acme") [
    {
      assertion = config.mailserver.acmeCertificateName == config.mailserver.fqdn;
      message = "When the certificate scheme is not 'acme' (mailserver.certificateScheme != \"acme\"), it is not possible to define mailserver.acmeCertificateName";
    }
  ];
}
