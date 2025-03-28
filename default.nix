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

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.mailserver;
in
{
  options.mailserver = {
    enable = mkEnableOption "nixos-mailserver";

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Automatically open ports in the firewall.";
    };

    fqdn = mkOption {
      type = types.str;
      example = "mx.example.com";
      description = "The fully qualified domain name of the mail server.";
    };

    domains = mkOption {
      type = types.listOf types.str;
      example = [ "example.com" ];
      default = [];
      description = "The domains that this mail server serves.";
    };

    certificateDomains = mkOption {
      type = types.listOf types.str;
      example = [ "imap.example.com" "pop3.example.com" ];
      default = [];
      description = ''
        ({option}`mailserver.certificateScheme` == `acme-nginx`)

        Secondary domains and subdomains for which it is necessary to generate a certificate.
      '';
    };

    messageSizeLimit = mkOption {
      type = types.int;
      example = 52428800;
      default = 20971520;
      description = "Message size limit enforced by Postfix.";
    };

    loginAccounts = mkOption {
      type = types.attrsOf (types.submodule ({ name, ... }: {
        options = {
          name = mkOption {
            type = types.str;
            example = "user1@example.com";
            description = "Username";
          };

          hashedPassword = mkOption {
            type = with types; nullOr str;
            default = null;
            example = "$6$evQJs5CFQyPAW09S$Cn99Y8.QjZ2IBnSu4qf1vBxDRWkaIZWOtmu1Ddsm3.H3CFpeVc0JU4llIq8HQXgeatvYhh5O33eWG3TSpjzu6/";
            description = ''
              The user's hashed password. Use `mkpasswd` as follows

              ```
              nix-shell -p mkpasswd --run 'mkpasswd -sm bcrypt'
              ```

              Warning: this is stored in plaintext in the Nix store!
              Use {option}`mailserver.loginAccounts.<name>.hashedPasswordFile` instead.
            '';
          };

          hashedPasswordFile = mkOption {
            type = with types; nullOr path;
            default = null;
            example = "/run/keys/user1-passwordhash";
            description = ''
              A file containing the user's hashed password. Use `mkpasswd` as follows

              ```
              nix-shell -p mkpasswd --run 'mkpasswd -sm bcrypt'
              ```
            '';
          };

          aliases = mkOption {
            type = with types; listOf types.str;
            example = ["abuse@example.com" "postmaster@example.com"];
            default = [];
            description = ''
              A list of aliases of this login account.
              Note: Use list entries like "@example.com" to create a catchAll
              that allows sending from all email addresses in these domain.
            '';
          };

          aliasesRegexp = mkOption {
            type = with types; listOf types.str;
            example = [''/^tom\..*@domain\.com$/''];
            default = [];
            description = ''
              Same as {option}`mailserver.aliases` but using PCRE (Perl compatible regex).
            '';
          };

          catchAll = mkOption {
            type = with types; listOf (enum cfg.domains);
            example = ["example.com" "example2.com"];
            default = [];
            description = ''
              For which domains should this account act as a catch all?
              Note: Does not allow sending from all addresses of these domains.
            '';
          };

          quota = mkOption {
            type = with types; nullOr types.str;
            default = null;
            example = "2G";
            description = ''
              Per user quota rules. Accepted sizes are `xx k/M/G/T` with the
              obvious meaning. Leave blank for the standard quota `100G`.
            '';
          };

          sieveScript = mkOption {
            type = with types; nullOr lines;
            default = null;
            example = ''
              require ["fileinto", "mailbox"];

              if address :is "from" "gitlab@mg.gitlab.com" {
                fileinto :create "GitLab";
                stop;
              }

              # This must be the last rule, it will check if list-id is set, and
              # file the message into the Lists folder for further investigation
              elsif header :matches "list-id" "<?*>" {
                fileinto :create "Lists";
                stop;
              }
            '';
            description = ''
              Per-user sieve script.
            '';
          };

          sendOnly = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Specifies if the account should be a send-only account.
              Emails sent to send-only accounts will be rejected from
              unauthorized senders with the `sendOnlyRejectMessage`
              stating the reason.
            '';
          };

          sendOnlyRejectMessage = mkOption {
            type = types.str;
            default = "This account cannot receive emails.";
            description = ''
              The message that will be returned to the sender when an email is
              sent to a send-only account. Only used if the account is marked
              as send-only.
            '';
          };
        };

        config.name = mkDefault name;
      }));
      example = {
        user1 = {
          hashedPassword = "$6$evQJs5CFQyPAW09S$Cn99Y8.QjZ2IBnSu4qf1vBxDRWkaIZWOtmu1Ddsm3.H3CFpeVc0JU4llIq8HQXgeatvYhh5O33eWG3TSpjzu6/";
        };
        user2 = {
          hashedPassword = "$6$oE0ZNv2n7Vk9gOf$9xcZWCCLGdMflIfuA0vR1Q1Xblw6RZqPrP94mEit2/81/7AKj2bqUai5yPyWE.QYPyv6wLMHZvjw3Rlg7yTCD/";
        };
      };
      description = ''
        The login account of the domain. Every account is mapped to a unix user,
        e.g. `user1@example.com`. To generate the passwords use `mkpasswd` as
        follows

        ```
        nix-shell -p mkpasswd --run 'mkpasswd -sm bcrypt'
        ```
      '';
      default = {};
    };

    ldap = {
      enable = mkEnableOption "LDAP support";

      uris  = mkOption {
        type = types.listOf types.str;
        example = literalExpression ''
          [
            "ldaps://ldap1.example.com"
            "ldaps://ldap2.example.com"
          ]
        '';
        description = ''
          URIs where your LDAP server can be reached
        '';
      };

      startTls = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to enable StartTLS upon connection to the server.
        '';
      };

      tlsCAFile = mkOption {
        type = types.path;
        default = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        defaultText = lib.literalMD "see [source](https://gitlab.com/simple-nixos-mailserver/nixos-mailserver/-/blob/master/default.nix)";
        description = ''
          Certifificate trust anchors used to verify the LDAP server certificate.
        '';
      };

      bind = {
        dn = mkOption {
          type = types.str;
          example = "cn=mail,ou=accounts,dc=example,dc=com";
          description = ''
            Distinguished name used by the mail server to do lookups
            against the LDAP servers.
          '';
        };

        passwordFile = mkOption {
          type = types.str;
          example = "/run/my-secret";
          description = ''
            A file containing the password required to authenticate against the LDAP servers.
          '';
        };
      };

      searchBase = mkOption {
        type = types.str;
        example = "ou=people,ou=accounts,dc=example,dc=com";
        description = ''
          Base DN at below which to search for users accounts.
        '';
      };

      searchScope = mkOption {
        type = types.enum [ "sub" "base" "one" ];
        default = "sub";
        description = ''
          Search scope below which users accounts are looked for.
        '';
      };

      dovecot = {
        userAttrs = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            LDAP attributes to be retrieved during userdb lookups.

            See the users_attrs reference at
            https://doc.dovecot.org/configuration_manual/authentication/ldap_settings_auth/#user-attrs
            in the Dovecot manual.
          '';
        };

        userFilter = mkOption {
          type = types.str;
          default = "mail=%u";
          example = "(&(objectClass=inetOrgPerson)(mail=%u))";
          description = ''
            Filter for user lookups in Dovecot.

            See the user_filter reference at
            https://doc.dovecot.org/configuration_manual/authentication/ldap_settings_auth/#user-filter
            in the Dovecot manual.
          '';
        };

        passAttrs = mkOption {
          type = types.str;
          default = "userPassword=password";
          description = ''
            LDAP attributes to be retrieved during passdb lookups.

            See the pass_attrs reference at
            https://doc.dovecot.org/configuration_manual/authentication/ldap_settings_auth/#pass-attrs
            in the Dovecot manual.
          '';
        };

        passFilter = mkOption {
          type = types.nullOr types.str;
          default = "mail=%u";
          example = "(&(objectClass=inetOrgPerson)(mail=%u))";
          description = ''
            Filter for password lookups in Dovecot.

            See the pass_filter reference for
            https://doc.dovecot.org/configuration_manual/authentication/ldap_settings_auth/#pass-filter
            in the Dovecot manual.
          '';
        };
      };

      postfix = {
        filter = mkOption {
          type = types.str;
          default = "mail=%s";
          example = "(&(objectClass=inetOrgPerson)(mail=%s))";
          description = ''
            LDAP filter used to search for an account by mail, where
            `%s` is a substitute for the address in
            question.
          '';
        };

        uidAttribute = mkOption {
          type = types.str;
          default = "mail";
          example = "uid";
          description = ''
            The LDAP attribute referencing the account name for a user.
          '';
        };

        mailAttribute = mkOption {
          type = types.str;
          default = "mail";
          description = ''
            The LDAP attribute holding mail addresses for a user.
          '';
        };
      };
    };

    indexDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Folder to store search indices. If null, indices are stored
        along with email, which could not necessarily be desirable,
        especially when {option}`mailserver.fullTextSearch.enable` is `true` since
        indices it creates are voluminous and do not need to be backed
        up.

        Be careful when changing this option value since all indices
        would be recreated at the new location (and clients would need
        to resynchronize).

        Note the some variables can be used in the file path. See
        https://doc.dovecot.org/configuration_manual/mail_location/#variables
        for details.
      '';
      example = "/var/lib/dovecot/indices";
    };

    fullTextSearch = {
      enable = mkEnableOption "Full text search indexing with xapian. This has significant performance and disk space cost.";
      autoIndex = mkOption {
        type = types.bool;
        default = true;
        description = "Enable automatic indexing of messages as they are received or modified.";
      };
      autoIndexExclude = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "\\Trash" "SomeFolder" "Other/*" ];
        description = ''
          Mailboxes to exclude from automatic indexing.
        '';
      };

      enforced = mkOption {
        type = types.enum [ "yes" "no" "body" ];
        default = "no";
        description = ''
          Fail searches when no index is available. If set to
          `body`, then only body searches (as opposed to
          header) are affected. If set to `no`, searches may
          fall back to a very slow brute force search.
        '';
      };

      minSize = mkOption {
        type = types.ints.between 3 1000;
        default = 3;
        description = "Minimum size of search terms";
      };
      memoryLimit = mkOption {
        type = types.nullOr types.int;
        default = null;
        example = 2000;
        description = "Memory limit for the indexer process, in MiB. If null, leaves the default (which is rather low), and if 0, no limit.";
      };

      maintenance = {
        enable = mkOption {
          type = types.bool;
          default = true;
          description = "Regularly optmize indices, as recommended by upstream.";
        };

        onCalendar = mkOption {
          type = types.str;
          default = "daily";
          description = "When to run the maintenance job. See systemd.time(7) for more information about the format.";
        };

        randomizedDelaySec = mkOption {
          type = types.int;
          default = 1000;
          description = "Run the maintenance job not exactly at the time specified with `onCalendar`, but plus or minus this many seconds.";
        };
      };
    };

    lmtpSaveToDetailMailbox = mkOption {
      type = types.enum ["yes" "no"];
      default = "yes";
      description = ''
        If an email address is delimited by a "+", should it be filed into a
        mailbox matching the string after the "+"?  For example,
        user1+test@example.com would be filed into the mailbox "test".
      '';
    };

    lmtpMemoryLimit = mkOption {
      type = types.int;
      default = 256;
      description = ''
        The memory limit for the LMTP service, in megabytes.
      '';
    };

    quotaStatusMemoryLimit = mkOption {
      type = types.int;
      default = 256;
      description = ''
        The memory limit for the quota-status service, in megabytes.
      '';
    };

    extraVirtualAliases = mkOption {
      type = let
        loginAccount = mkOptionType {
          name = "Login Account";
          check = (account: builtins.elem account (builtins.attrNames cfg.loginAccounts));
        };
      in with types; attrsOf (either loginAccount (nonEmptyListOf loginAccount));
      example = {
        "info@example.com" = "user1@example.com";
        "postmaster@example.com" = "user1@example.com";
        "abuse@example.com" = "user1@example.com";
        "multi@example.com" = [ "user1@example.com" "user2@example.com" ];
      };
      description = ''
        Virtual Aliases. A virtual alias `"info@example.com" = "user1@example.com"` means that
        all mail to `info@example.com` is forwarded to `user1@example.com`. Note
        that it is expected that `postmaster@example.com` and `abuse@example.com` is
        forwarded to some valid email address. (Alternatively you can create login
        accounts for `postmaster` and (or) `abuse`). Furthermore, it also allows
        the user `user1@example.com` to send emails as `info@example.com`.
        It's also possible to create an alias for multiple accounts. In this
        example all mails for `multi@example.com` will be forwarded to both
        `user1@example.com` and `user2@example.com`.
      '';
      default = {};
    };

    forwards = mkOption {
      type = with types; attrsOf (either (listOf str) str);
      example = {
        "user@example.com" = "user@elsewhere.com";
      };
      description = ''
        To forward mails to an external address. For instance,
        the value {`"user@example.com" = "user@elsewhere.com";}`
        means that mails to `user@example.com` are forwarded to
        `user@elsewhere.com`. The difference with the
        {option}`mailserver.extraVirtualAliases` option is that `user@elsewhere.com`
        can't send mail as `user@example.com`. Also, this option
        allows to forward mails to external addresses.
      '';
      default = {};
    };

    rejectSender = mkOption {
      type = types.listOf types.str;
      example = [ "example.com" "spammer@example.net" ];
      description = ''
        Reject emails from these addresses from unauthorized senders.
        Use if a spammer is using the same domain or the same sender over and over.
      '';
      default = [];
    };

    rejectRecipients = mkOption {
      type = types.listOf types.str;
      example = [ "sales@example.com" "info@example.com" ];
      description = ''
        Reject emails addressed to these local addresses from unauthorized senders.
        Use if a spammer has found email addresses in a catchall domain but you do
        not want to disable the catchall.
      '';
      default = [];
    };

    vmailUID = mkOption {
      type = types.int;
      default = 5000;
      description = ''
        The unix UID of the virtual mail user.  Be mindful that if this is
        changed, you will need to manually adjust the permissions of
        `mailDirectory`.
      '';
    };

    vmailUserName = mkOption {
      type = types.str;
      default = "virtualMail";
      description = ''
        The user name and group name of the user that owns the directory where all
        the mail is stored.
      '';
    };

    vmailGroupName = mkOption {
      type = types.str;
      default = "virtualMail";
      description = ''
        The user name and group name of the user that owns the directory where all
        the mail is stored.
      '';
    };

    mailDirectory = mkOption {
      type = types.path;
      default = "/var/vmail";
      description = ''
        Where to store the mail.
      '';
    };

    useFsLayout = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Sets whether dovecot should organize mail in subdirectories:

        - /var/vmail/example.com/user/.folder.subfolder/ (default layout)
        - /var/vmail/example.com/user/folder/subfolder/  (FS layout)

        See https://doc.dovecot.org/main/core/config/mailbox_formats/maildir.html#maildir-mailbox-format for details.
      '';
    };

    useUTF8FolderNames = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Store mailbox names on disk using UTF-8 instead of modified UTF-7 (mUTF-7).
      '';
    };

    hierarchySeparator = mkOption {
      type = types.str;
      default = ".";
      description = ''
        The hierarchy separator for mailboxes used by dovecot for the namespace 'inbox'.
        Dovecot defaults to "." but recommends "/".
        This affects how mailboxes appear to mail clients and sieve scripts.
        For instance when using "." then in a sieve script "example.com" would refer to the mailbox "com" in the parent mailbox "example".
        This does not determine the way your mails are stored on disk.
        See https://doc.dovecot.org/main/core/config/namespaces.html#namespaces for details.
      '';
    };

    mailboxes = mkOption {
      description = ''
        The mailboxes for dovecot.
        Depending on the mail client used it might be necessary to change some mailbox's name.
      '';
      default = {
        Trash = {
          auto = "no";
          specialUse = "Trash";
        };
        Junk = {
          auto = "subscribe";
          specialUse = "Junk";
        };
        Drafts = {
          auto = "subscribe";
          specialUse = "Drafts";
        };
        Sent = {
          auto = "subscribe";
          specialUse = "Sent";
        };
      };
    };

    certificateScheme = let
      schemes = [ "manual" "selfsigned" "acme-nginx" "acme" ];
      translate = i: warn "Setting mailserver.certificateScheme by number is deprecated, please use names instead: 'mailserver.certificateScheme = ${builtins.toString i}' can be replaced by 'mailserver.certificateScheme = \"${(builtins.elemAt schemes (i - 1))}\"'."
        (builtins.elemAt schemes (i - 1));
    in mkOption {
      type = with types; coercedTo (enum [ 1 2 3 ]) translate (enum schemes);
      default = "selfsigned";
      description = ''
        The scheme to use for managing TLS certificates:

        1. `manual`: you specify locations via {option}`mailserver.certificateFile` and
           {option}`mailserver.keyFile` and manually copy certificates there.
        2. `selfsigned`: you let the server create new (self-signed) certificates on the fly.
        3. `acme-nginx`: you let the server request certificates from [Let's Encrypt](https://letsencrypt.org)
           via NixOS' ACME module. By default, this will set up a stripped-down Nginx server for
           {option}`mailserver.fqdn` and open port 80. For this to work, the FQDN must be properly
           configured to point to your server (see the [setup guide](setup-guide.rst) for more information).
        4. `acme`: you already have an ACME certificate set up (for example, you're already running a TLS-enabled
           Nginx server on the FQDN). This is better than `manual` because the appropriate services will be reloaded
           when the certificate is renewed.
      '';
    };

    certificateFile = mkOption {
      type = types.path;
      example = "/root/mail-server.crt";
      description = ''
        ({option}`mailserver.certificateScheme` == `manual`)

        Location of the certificate.
      '';
    };

    keyFile = mkOption {
      type = types.path;
      example = "/root/mail-server.key";
      description = ''
        ({option}`mailserver.certificateScheme` == `manual`)

        Location of the key file.
      '';
    };

    certificateDirectory = mkOption {
      type = types.path;
      default = "/var/certs";
      description = ''
        ({option}`mailserver.certificateScheme` == `selfsigned`)

        This is the folder where the self-signed certificate will be created. The name is
        hardcoded to "cert-DOMAIN.pem" and "key-DOMAIN.pem" and the
        certificate is valid for 10 years.
      '';
    };

    acmeCertificateName = mkOption {
      type = types.str;
      default = cfg.fqdn;
      example = "example.com";
      description = ''
          ({option}`mailserver.certificateScheme` == `acme`)

        When the `acme` `certificateScheme` is selected, you can use this option
        to override the default certificate name. This is useful if you've
        generated a wildcard certificate, for example.
      '';
    };

    enableImap = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to enable IMAP with STARTTLS on port 143.
      '';
    };

    imapMemoryLimit = mkOption {
      type = types.int;
      default = 256;
      description = ''
        The memory limit for the imap service, in megabytes.
      '';
    };

    enableImapSsl = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to enable IMAP with TLS in wrapper-mode on port 993.
      '';
    };

    enableSubmission = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to enable SMTP with STARTTLS on port 587.
      '';
    };

    enableSubmissionSsl = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to enable SMTP with TLS in wrapper-mode on port 465.
      '';
    };

    enablePop3 = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to enable POP3 with STARTTLS on port on port 110.
      '';
    };

    enablePop3Ssl = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to enable POP3 with TLS in wrapper-mode on port 995.
      '';
    };

    enableManageSieve = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to enable ManageSieve, setting this option to true will open
        port 4190 in the firewall.

        The ManageSieve protocol allows users to manage their Sieve scripts on
        a remote server with a supported client, including Thunderbird.
      '';
    };

    sieveDirectory = mkOption {
      type = types.path;
      default = "/var/sieve";
      description = ''
        Where to store the sieve scripts.
      '';
    };

    virusScanning = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to activate virus scanning. Note that virus scanning is _very_
        expensive memory wise.
      '';
    };

    dkimSigning = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to activate dkim signing.
      '';
    };

    dkimSelector = mkOption {
      type = types.str;
      default = "mail";
      description = ''
        The DKIM selector.
      '';
    };

    dkimKeyDirectory = mkOption {
      type = types.path;
      default = "/var/dkim";
      description = ''
        The DKIM directory.
      '';
    };

    dkimKeyBits = mkOption {
        type = types.int;
        default = 1024;
        description = ''
            How many bits in generated DKIM keys. RFC6376 advises minimum 1024-bit keys.

            If you have already deployed a key with a different number of bits than specified
            here, then you should use a different selector ({option}`mailserver.dkimSelector`). In order to get
            this package to generate a key with the new number of bits, you will either have to
            change the selector or delete the old key file.
        '';
    };

    dkimHeaderCanonicalization = mkOption {
        type = types.enum ["relaxed" "simple"];
        default = "relaxed";
        description = ''
          DKIM canonicalization algorithm for message headers.

          See https://datatracker.ietf.org/doc/html/rfc6376/#section-3.4 for details.
        '';
    };

    dkimBodyCanonicalization = mkOption {
        type = types.enum ["relaxed" "simple"];
        default = "relaxed";
        description = ''
          DKIM canonicalization algorithm for message bodies.

          See https://datatracker.ietf.org/doc/html/rfc6376/#section-3.4 for details.
        '';
    };

    dmarcReporting = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to send out aggregated, daily DMARC reports in response to incoming
          mail, when the sender domain defines a DMARC policy including the RUA tag.

          This is helpful for the mail ecosystem, because it allows third parties to
          get notified about SPF/DKIM violations originating from their sender domains.

          See https://rspamd.com/doc/modules/dmarc.html#reporting
        '';
      };

      localpart = mkOption {
        type = types.str;
        default = "dmarc-noreply";
        example = "dmarc-report";
        description = ''
          The local part of the email address used for outgoing DMARC reports.
        '';
      };

      domain = mkOption {
        type = types.enum (cfg.domains);
        example = "example.com";
        description = ''
          The domain from which outgoing DMARC reports are served.
        '';
      };

      email = mkOption {
        type = types.str;
        default = with cfg.dmarcReporting; "${localpart}@${domain}";
        defaultText = literalExpression ''"''${localpart}@''${domain}"'';
        readOnly = true;
        description = ''
          The email address used for outgoing DMARC reports. Read-only.
        '';
      };

      organizationName = mkOption {
        type = types.str;
        example = "ACME Corp.";
        description = ''
          The name of your organization used in the `org_name` attribute in
          DMARC reports.
        '';
      };

      fromName = mkOption {
        type = types.str;
        default = cfg.dmarcReporting.organizationName;
        defaultText = literalMD "{option}`mailserver.dmarcReporting.organizationName`";
        description = ''
          The sender name for DMARC reports. Defaults to the organization name.
        '';
      };
    };

    debug = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to enable verbose logging for mailserver related services. This
        intended be used for development purposes only, you probably don't want
        to enable this unless you're hacking on nixos-mailserver.
      '';
    };

    maxConnectionsPerUser = mkOption {
      type = types.int;
      default = 100;
      description = ''
        Maximum number of IMAP/POP3 connections allowed for a user from each IP address.
        E.g. a value of 50 allows for 50 IMAP and 50 POP3 connections at the same
        time for a single user.
      '';
    };

    localDnsResolver = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Runs a local DNS resolver (kresd) as recommended when running rspamd. This prevents your log file from filling up with rspamd_monitored_dns_mon entries.
      '';
    };

    recipientDelimiter = mkOption {
      type = types.str;
      default = "+";
      description = ''
        Configure the recipient delimiter.
      '';
    };

    redis = {
      address = mkOption {
        type = types.str;
        # read the default from nixos' redis module
        default = let
          cf = config.services.redis.servers.rspamd.bind;
          cfdefault = if cf == null then "127.0.0.1" else cf;
          ips = lib.strings.splitString " " cfdefault;
          ip = lib.lists.head (ips ++ [ "127.0.0.1" ]);
          isIpv6 = ip: lib.lists.elem ":" (lib.stringToCharacters ip);
        in
        if (ip == "0.0.0.0" || ip == "::")
        then "127.0.0.1"
        else if isIpv6 ip then "[${ip}]" else ip;
        defaultText = lib.literalMD "computed from `config.services.redis.servers.rspamd.bind`";
        description = ''
          Address that rspamd should use to contact redis.
        '';
      };

      port = mkOption {
        type = types.port;
        default = config.services.redis.servers.rspamd.port;
        defaultText = lib.literalExpression "config.services.redis.servers.rspamd.port";
        description = ''
          Port that rspamd should use to contact redis.
        '';
      };

      password = mkOption {
        type = types.nullOr types.str;
        default = config.services.redis.servers.rspamd.requirePass;
        defaultText = lib.literalExpression "config.services.redis.servers.rspamd.requirePass";
        description = ''
          Password that rspamd should use to contact redis, or null if not required.
        '';
      };
    };

    rewriteMessageId = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Rewrites the Message-ID's hostname-part of outgoing emails to the FQDN.
        Please be aware that this may cause problems with some mail clients
        relying on the original Message-ID.
      '';
    };

    smtpdForbidBareNewline = mkOption {
      type = types.bool;
      default = true;
      description = ''
        With "smtpd_forbid_bare_newline = yes", the Postfix SMTP server
        disconnects a remote SMTP client that sends a line ending in a 'bare
        newline'.

        This feature was added in Postfix 3.8.4 against SMTP Smuggling and will
        default to "yes" in Postfix 3.9.

        https://www.postfix.org/smtp-smuggling.html
      '';
    };

    sendingFqdn = mkOption {
      type = types.str;
      default = cfg.fqdn;
      defaultText = lib.literalMD "{option}`mailserver.fqdn`";
      example = "myserver.example.com";
      description = ''
        The fully qualified domain name of the mail server used to
        identify with remote servers.

        If this server's IP serves purposes other than a mail server,
        it may be desirable for the server to have a name other than
        that to which the user will connect.  For example, the user
        might connect to mx.example.com, but the server's IP has
        reverse DNS that resolves to myserver.example.com; in this
        scenario, some mail servers may reject or penalize the
        message.

        This setting allows the server to identify as
        myserver.example.com when forwarding mail, independently of
        {option}`mailserver.fqdn` (which, for SSL reasons, should generally be the name
        to which the user connects).

        Set this to the name to which the sending IP's reverse DNS
        resolves.
      '';
    };

    policydSPFExtraConfig = mkOption {
      type = types.lines;
      default = "";
      example = ''
        skip_addresses = 127.0.0.0/8,::ffff:127.0.0.0/104,::1
      '';
      description = ''
        Extra configuration options for policyd-spf. This can be use to among
        other things skip spf checking for some IP addresses.
      '';
    };

    monitoring = {
      enable = mkEnableOption "monitoring via monit";

      alertAddress = mkOption {
        type = types.str;
        description = ''
          The email address to send alerts to.
        '';
      };

      config = mkOption {
        type = types.str;
        default = ''
          set daemon 120 with start delay 60
          set mailserver
              localhost

          set httpd port 2812 and use address localhost
              allow localhost
              allow admin:obwjoawijerfoijsiwfj29jf2f2jd

          check filesystem root with path /
                if space usage > 80% then alert
                if inode usage > 80% then alert

          check system $HOST
                if cpu usage > 95% for 10 cycles then alert
                if memory usage > 75% for 5 cycles then alert
                if swap usage > 20% for 10 cycles then alert
                if loadavg (1min) > 90 for 15 cycles then alert
                if loadavg (5min) > 80 for 10 cycles then alert
                if loadavg (15min) > 70 for 8 cycles then alert

          check process sshd with pidfile /var/run/sshd.pid
                start program  "${pkgs.systemd}/bin/systemctl start sshd"
                stop program  "${pkgs.systemd}/bin/systemctl stop sshd"
                if failed port 22 protocol ssh for 2 cycles then restart

          check process postfix with pidfile /var/lib/postfix/queue/pid/master.pid
                start program = "${pkgs.systemd}/bin/systemctl start postfix"
                stop program = "${pkgs.systemd}/bin/systemctl stop postfix"
                if failed port 25 protocol smtp for 5 cycles then restart

          check process dovecot with pidfile /var/run/dovecot2/master.pid
                start program = "${pkgs.systemd}/bin/systemctl start dovecot2"
                stop program = "${pkgs.systemd}/bin/systemctl stop dovecot2"
                if failed host ${cfg.fqdn} port 993 type tcpssl sslauto protocol imap for 5 cycles then restart

          check process rspamd with matching "rspamd: main process"
                start program = "${pkgs.systemd}/bin/systemctl start rspamd"
                stop program = "${pkgs.systemd}/bin/systemctl stop rspamd"
        '';
        defaultText = lib.literalMD "see [source](https://gitlab.com/simple-nixos-mailserver/nixos-mailserver/-/blob/master/default.nix)";
        description = ''
          The configuration used for monitoring via monit.
          Use a mail address that you actively check and set it via 'set alert ...'.
        '';
      };
    };

    borgbackup = {
      enable = mkEnableOption "backup via borgbackup";

      repoLocation = mkOption {
        type = types.str;
        default = "/var/borgbackup";
        description = ''
          The location where borg saves the backups.
          This can be a local path or a remote location such as user@host:/path/to/repo.
          It is exported and thus available as an environment variable to
          {option}`mailserver.borgbackup.cmdPreexec` and {option}`mailserver.borgbackup.cmdPostexec`.
        '';
      };

      startAt = mkOption {
        type = types.str;
        default = "hourly";
        description = "When or how often the backup should run. Must be in the format described in systemd.time 7.";
      };

      user = mkOption {
        type = types.str;
        default = "virtualMail";
        description = "The user borg and its launch script is run as.";
      };

      group = mkOption {
        type = types.str;
        default = "virtualMail";
        description = "The group borg and its launch script is run as.";
      };

      compression = {
        method = mkOption {
          type = types.nullOr (types.enum ["none" "lz4" "zstd" "zlib" "lzma"]);
          default = null;
          description = "Leaving this unset allows borg to choose. The default for borg 1.1.4 is lz4.";
        };

        level = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = ''
            Denotes the level of compression used by borg.
            Most methods accept levels from 0 to 9 but zstd which accepts values from 1 to 22.
            If null the decision is left up to borg.
          '';
        };

        auto = mkOption {
          type = types.bool;
          default = false;
          description = "Leaves it to borg to determine whether an individual file should be compressed.";
        };
      };

      encryption = {
        method = mkOption {
          type = types.enum [
            "none"
            "authenticated"
            "authenticated-blake2"
            "repokey"
            "keyfile"
            "repokey-blake2"
            "keyfile-blake2"
          ];
          default = "none";
          description = ''
            The backup can be encrypted by choosing any other value than 'none'.
            When using encryption the password/passphrase must be provided in `passphraseFile`.
          '';
        };

        passphraseFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Path to a file containing the encryption password or passphrase.";
        };
      };

      name = mkOption {
        type = types.str;
        default = "{hostname}-{user}-{now}";
        description = ''
          The name of the individual backups as used by borg.
          Certain placeholders will be replaced by borg.
        '';
      };

      locations = mkOption {
        type = types.listOf types.path;
        default = [cfg.mailDirectory];
        defaultText = lib.literalExpression "[ config.mailserver.mailDirectory ]";
        description = "The locations that are to be backed up by borg.";
      };

      extraArgumentsForInit = mkOption {
        type = types.listOf types.str;
        default = ["--critical"];
        description = "Additional arguments to add to the borg init command line.";
      };

      extraArgumentsForCreate = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Additional arguments to add to the borg create command line e.g. '--stats'.";
      };

      cmdPreexec = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The command to be executed before each backup operation.
          This is called prior to borg init in the same script that runs borg init and create and `cmdPostexec`.
        '';
        example = ''
          export BORG_RSH="ssh -i /path/to/private/key"
        '';
      };

      cmdPostexec = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The command to be executed after each backup operation.
          This is called after borg create completed successfully and in the same script that runs
          `cmdPreexec`, borg init and create.
        '';
      };

    };

    backup = {
      enable = mkEnableOption "backup via rsnapshot";

      snapshotRoot = mkOption {
        type = types.path;
        default = "/var/rsnapshot";
        description = ''
          The directory where rsnapshot stores the backup.
        '';
      };

      cmdPreexec = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          The command to be executed before each backup operation. This is wrapped in a shell script to be called by rsnapshot.
        '';
      };

      cmdPostexec = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "The command to be executed after each backup operation. This is wrapped in a shell script to be called by rsnapshot.";
      };

      retain = {
        hourly = mkOption {
          type = types.int;
          default = 24;
          description = "How many hourly snapshots are retained.";
        };
        daily = mkOption {
          type = types.int;
          default = 7;
          description = "How many daily snapshots are retained.";
        };
        weekly = mkOption {
          type = types.int;
          default = 54;
          description = "How many weekly snapshots are retained.";
        };
      };

      cronIntervals = mkOption {
        type = types.attrsOf types.str;
        default = {
                   # minute, hour, day-in-month, month, weekday (0 = sunday)
          hourly = " 0  *  *  *  *"; # Every full hour
          daily  = "30  3  *  *  *"; # Every day at 3:30
          weekly = " 0  5  *  *  0"; # Every sunday at 5:00 AM
        };
        description = ''
          Periodicity at which intervals should be run by cron.
          Note that the intervals also have to exist in configuration
          as retain options.
        '';
      };
    };
  };

  imports = [
    (lib.mkRemovedOptionModule [ "mailserver" "fullTextSearch" "maxSize" ] ''
    This option is not needed since fts-xapian 1.8.3
    '')
    (lib.mkRemovedOptionModule [ "mailserver" "fullTextSearch" "indexAttachments" ] ''
    Text attachments are always indexed since fts-xapian 1.4.8
    '')
    (lib.mkRenamedOptionModule
      [ "mailserver" "rebootAfterKernelUpgrade" "enable" ]
      [ "system" "autoUpgrade" "allowReboot" ]
    )
    (lib.mkRemovedOptionModule [ "mailserver" "rebootAfterKernelUpgrade" "method" ] ''
    Use `system.autoUpgrade` instead.
    '')
    ./mail-server/assertions.nix
    ./mail-server/borgbackup.nix
    ./mail-server/debug.nix
    ./mail-server/rsnapshot.nix
    ./mail-server/clamav.nix
    ./mail-server/monit.nix
    ./mail-server/users.nix
    ./mail-server/environment.nix
    ./mail-server/networking.nix
    ./mail-server/systemd.nix
    ./mail-server/dovecot.nix
    ./mail-server/opendkim.nix
    ./mail-server/postfix.nix
    ./mail-server/rspamd.nix
    ./mail-server/nginx.nix
    ./mail-server/kresd.nix
  ];
}
