Add SOGo, a groupware server
============================

Getting the NixOS module for SOGo to work with SNM requires some work.

Before we begin, we extend the SNM module with attributes to store first and last names of the mail user, so we get decent entries in SOGo's address book.

The module extension file is called ``base.nix``:

.. code:: nix

    { lib, pkgs, ... }:
    let release = "nixos-21.11";
    in {
     imports = [
       (builtins.fetchTarball {
         url = "https://gitlab.com/simple-nixos-mailserver/nixos-mailserver/-/archive/${release}/nixos-mailserver-${release}.tar.gz";
         # This hash needs to be updated
         sha256 = "0000000000000000000000000000000000000000000000000000";
        })
      ];

      options = with lib; with types; {
         mailserver.loginAccounts = mkOption {
           options.firstName = mkOption {
             type = with types; nullOr str;
             example = "John";
             description = "The first name (given name) of the person owning the mailbox";
             default = null;
           };
           options.lastName = mkOption {
             type = with types; nullOr str;
             example = "Doe";
             description = "The last name (surname/family name) of the person owning the mailbox";
             default = null;
           };
         };
      };
    }


Configure SNM normally, additionally set ``firstName`` and ``lastName``:

.. code:: nix

    { lib, pkgs, ... }:
    {
      imports = [
        ./base.nix
        ./sogo.nix
      ];

      mailserver = {
        ...
        loginAccounts = {
          "john.doe@example.com" = {
            ...
            firstName = "John";
            lastName = "Doe";
          };
        };
      };
    };


In the file ``sogo.nix`` we do the heavy lifting:

- SOGo provides auth via LDAP, C.A.S, SAML2 or SQL. Here we will store users in OpenLDAP, because the NixOS module provides a nice way to define contents of OpenLDAP declaratively.
- Our declarative ``config.mailserver.loginAccounts`` are converted to ldiff strings and saved in ``ldiffContent``.
- We use sha512-crypt hashes, because OpenLDAP supports it out of the box. Generate passwords with ``mkpasswd -m sha-512 "super secret password"``. (Future work: It should be possible to enable blf-crypt in OpenLDAP, then we could use the recommended bcrypt hashes.)
- Accounts which are used for send only are not created in LDAP.

.. note::

    CAUTION: Because we use ``services.openldap.declarativeContents`` all other contents will be removed from LDAP and changes will be lost after rebuilds!


.. note::

    Replace missing passwords denoted by ``<...>`` with actual passwords or hashes.


.. code:: nix

    { config, pkgs, lib, ... }:
    with lib;

    let
      mailAccounts = config.mailserver.loginAccounts;
      dnBase = "ou=users,dc=example,dc=com";
      dnBaseServices = "ou=services,dc=example,dc=com";
      ldiffContent = (concatStrings
        (flip mapAttrsToList mailAccounts (mail: user:
          if user.sendOnly != true then (
            "dn: uid=" + mail + "," + dnBase + "\n"
          + "objectClass: top\n"
          + "objectClass: person\n"
          + "objectClass: inetOrgPerson\n"
          + "uid: " + mail + "\n"
          + "structuralObjectClass: inetOrgPerson\n"
          + "mail: " + mail + "\n"
          + "userPassword: {CRYPT}" + user.hashedPassword + "\n"
          + (if user.firstName != null then ("givenName: " + user.firstName + "\n") else "")
          + "sn: " + (if user.lastName != null then (user.lastName) else (head (splitString "@" mail ))) + "\n"
          + (if (user.firstName != null && user.lastName != null) then "displayName: " + user.firstName + " " + user.lastName + "\n" else "" )
          + "cn: " + (if (user.firstName != null && user.lastName != null) then user.firstName + " " + user.lastName + "\n" else mail + "\n" )
          + "\n"
          ) else ""
        ))
      );

    in {
      services.openldap = {
        enable = true;
        urlList = [ "ldap://127.0.0.1/" "ldap://[::1]/"];

        settings = {
          attrs.olcLogLevel = [ "stats" ];
          attrs.olcPasswordCryptSaltFormat = "$6$%.16s";
          attrs.olcPasswordHash = "{CRYPT}";

          children = {
            "cn=schema".includes = [
               "${pkgs.openldap}/etc/schema/core.ldif"
               "${pkgs.openldap}/etc/schema/cosine.ldif"
               "${pkgs.openldap}/etc/schema/inetorgperson.ldif"
            ];
            "olcDatabase={-1}frontend" = {
              attrs = {
                objectClass = "olcDatabaseConfig";
                olcDatabase = "{-1}frontend";
              };
            };
            "olcDatabase={0}config" = {
              attrs = {
                objectClass = "olcDatabaseConfig";
                olcDatabase = "{0}config";
                olcAccess = [ "{0}to * by * none break" ];
              };
            };
            "olcDatabase={1}mdb" = {
              attrs = {
                objectClass = [ "olcDatabaseConfig" "olcMdbConfig" ];
                olcDatabase = "{1}mdb";
                olcDbDirectory = "/var/lib/ldap";
                olcDbIndex = [
                  "objectClass eq"
                  "cn pres,eq,sub"
                  "uid pres,eq"
                  "sn pres,eq,subany,sub"
                  "givenName eq,sub"
                  "mail eq,sub"
                  "displayName eq,sub"
                  "ou eq"
                ];
                olcSuffix = "dc=example,dc=com";
                olcRootDN = "cn=admin,dc=example,dc=com";
                olcRootPW = "<HASH generated by slappasswd -s secret>";
              };
            };
          };
        };

        declarativeContents."dc=example,dc=com" = ''
          # base
          dn: dc=example,dc=com
          objectClass: top
          objectClass: dcObject
          objectClass: organization
          o: example.com
          dc: example
          structuralObjectClass: organization

          # users group
          dn: ${dnBase}
          objectClass: organizationalUnit
          objectClass: top
          ou: users

          # service group
          dn: ${dnBaseServices}
          objectClass: organizationalUnit
          objectClass: top
          ou: services

          # sogo service user
          dn: cn=sogo,${dnBaseServices}
          objectClass: simpleSecurityObject
          objectClass: organizationalRole
          cn: sogo
          userPassword: {CRYPT}<Hash generated by mkpasswd -m sha-512 "super secret password", starts with $6$>
          description: LDAP sogo user
          structuralObjectClass: organizationalRole

          # mail users
          ${ldiffContent}
        '';
      };

      services.postgresql = {
        ensureDatabases = [ "sogo" ];
        ensureUsers = [{
          name = "sogo";
          ensurePermissions = {
            "DATABASE sogo" = "ALL PRIVILEGES";
          };
        }];
        initialScript = pkgs.writeText "backend-initScript" ''
          ALTER ROLE sogo PASSWORD '<secret!>'
        '';
      };

      services.sogo = {
        enable = true;
        vhostName = "sogo.example.com";
        language = "German";
        timezone = "Europe/Berlin";
        extraConfig = ''
          SOGoProfileURL = "postgresql://sogo:PGSQL_PW@127.0.0.1:5432/sogo/sogo_user_profile";
          OCSFolderInfoURL = "postgresql://sogo:PGSQL_PW@127.0.0.1:5432/sogo/sogo_folder_info";
          OCSSessionsFolderURL = "postgresql://sogo:PGSQL_PW@127.0.0.1:5432/sogo/sogo_sessions_folder";
          OCSCacheFolderURL = "postgresql://sogo:PGSQL_PW@127.0.0.1:5432/sogo/sogo_cache_folder";
          OCSStoreURL = "postgresql://sogo:PGSQL_PW@127.0.0.1:5432/sogo/sogo_store";
          OCSAclURL = "postgresql://sogo:PGSQL_PW@127.0.0.1:5432/sogo/sogo_acl";
          SOGoAppointmentSendEMailNotifications = YES;
          SOGoCalendarDefaultRoles = (
              PublicDAndTViewer,
              ConfidentialDAndTViewer
          );
          SOGoCalendarDefaultReminder = "-PT15M";
          SOGoFirstDayOfWeek = 1;
          SOGoMailDomain = example.com;
          SOGoIMAPServer = 127.0.0.1;
          SOGoDraftsFolderName = Drafts;
          SOGoSentFolderName = Sent;
          SOGoTrashFolderName = Trash;
          SOGoJunkFolderName = Junk;
          SOGoMailingMechanism = smtp;
          SOGoSMTPServer = "smtp://127.0.0.1";
          SOGoSieveServer = "sieve://127.0.0.1";
          SOGoSieveFolderEncoding = "UTF-8";
          SOGoSieveScriptsEnabled = YES;
          SOGoVacationEnabled = YES;
          SOGoRefreshViewCheck = "every_minute";
          SOGoUserSources = (
            {
                type = ldap;
                CNFieldName = cn;
                IDFieldName = uid;
                UIDFieldName = uid;
                baseDN = "${dnBase}";
                bindDN = "cn=sogo,${dnBaseServices}";
                bindPassword = "LDAP_BINDPW";
                canAuthenticate = YES;
                displayName = "Shared Addresses";
                hostname = "ldap://127.0.0.1:389";
                id = public;
                isAddressBook = YES;
                userPasswordAlgorithm = sha512-crypt;
            }
          );
        '';
        configReplaces = {
          LDAP_BINDPW = "<path to ldap password file>";
          PGSQL_PW = "<path to pgsql password file>";
        };
      };

      services.memcached.enable = true;

      services.cron.systemCronJobs = [
        "30 0 * * * sogo ${pkgs.sogo}/bin/sogo-tool expire-sessions 60 > /dev/null 2>&1"
        "3  * * * * sogo ${pkgs.sogo}/bin/sogo-tool backup \"/var/backup/sogo/\" ALL > /dev/null 2>&1"
      ];
    }
