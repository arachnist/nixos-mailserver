{ config, lib, ... }:
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
  ] ++ lib.optionals (config.mailserver.enable && config.mailserver.certificateScheme != "acme") [
    {
      assertion = config.mailserver.acmeCertificateName == config.mailserver.fqdn;
      message = "When the certificate scheme is not 'acme' (mailserver.certificateScheme != \"acme\"), it is not possible to define mailserver.acmeCertificateName";
    }
  ] ++ lib.optionals (config.mailserver.enable && config.mailserver.dkimPrivateKeyFiles != null) [
    {
      assertion = config.mailserver.dkimKeyBits == null;
      message = "When you bring your own DKIM private keys (mailserver.dkimPrivateKeyFiles != null), you must not specify key generation options (mailserver.dkimKeyBits)";
    }
  ] ++ lib.optionals (config.mailserver.enable && config.mailserver.dkimPrivateKeyFiles == null) [
    {
      assertion = config.mailserver.dkimKeyBits != null;
      message = "When generating DKIM private keys (mailserver.dkimPrivateKeyFiles = null), you must specify key generation options (mailserver.dkimKeyBits)";
    }
  ];
}
