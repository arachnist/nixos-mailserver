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

with (import ./common.nix { inherit config pkgs lib; });

let
  cfg = config.mailserver;

  passwdDir = "/run/dovecot2";
  passwdFile = "${passwdDir}/passwd";
  userdbFile = "${passwdDir}/userdb";
  # This file contains the ldap bind password
  ldapConfFile = "${passwdDir}/dovecot-ldap.conf.ext";
  bool2int = x: if x then "1" else "0";

  maildirLayoutAppendix = lib.optionalString cfg.useFsLayout ":LAYOUT=fs";
  maildirUTF8FolderNames = lib.optionalString cfg.useUTF8FolderNames ":UTF-8";

  # maildir in format "/${domain}/${user}"
  dovecotMaildir =
    "maildir:${cfg.mailDirectory}/%d/%n${maildirLayoutAppendix}${maildirUTF8FolderNames}"
    + (lib.optionalString (cfg.indexDir != null)
       ":INDEX=${cfg.indexDir}/%d/%n"
      );

  postfixCfg = config.services.postfix;
  dovecot2Cfg = config.services.dovecot2;

  stateDir = "/var/lib/dovecot";

  pipeBin = pkgs.stdenv.mkDerivation {
    name = "pipe_bin";
    src = ./dovecot/pipe_bin;
    buildInputs = with pkgs; [ makeWrapper coreutils bash rspamd ];
    buildCommand = ''
      mkdir -p $out/pipe/bin
      cp $src/* $out/pipe/bin/
      chmod a+x $out/pipe/bin/*
      patchShebangs $out/pipe/bin

      for file in $out/pipe/bin/*; do
        wrapProgram $file \
          --set PATH "${pkgs.coreutils}/bin:${pkgs.rspamd}/bin"
      done
    '';
  };


  ldapConfig = pkgs.writeTextFile {
    name = "dovecot-ldap.conf.ext.template";
    text = ''
      ldap_version = 3
      uris = ${lib.concatStringsSep " " cfg.ldap.uris}
      ${lib.optionalString cfg.ldap.startTls ''
      tls = yes
      ''}
      tls_require_cert = hard
      tls_ca_cert_file = ${cfg.ldap.tlsCAFile}
      dn = ${cfg.ldap.bind.dn}
      sasl_bind = no
      auth_bind = yes
      base = ${cfg.ldap.searchBase}
      scope = ${mkLdapSearchScope cfg.ldap.searchScope}
      ${lib.optionalString (cfg.ldap.dovecot.userAttrs != null) ''
      user_attrs = ${cfg.ldap.dovecot.userAttrs}
      ''}
      user_filter = ${cfg.ldap.dovecot.userFilter}
      ${lib.optionalString (cfg.ldap.dovecot.passAttrs != "") ''
      pass_attrs = ${cfg.ldap.dovecot.passAttrs}
      ''}
      pass_filter = ${cfg.ldap.dovecot.passFilter}
    '';
  };

  setPwdInLdapConfFile = appendLdapBindPwd {
    name = "ldap-conf-file";
    file = ldapConfig;
    prefix = ''dnpass = "'';
    suffix = ''"'';
    passwordFile = cfg.ldap.bind.passwordFile;
    destination = ldapConfFile;
  };

  genPasswdScript = pkgs.writeScript "generate-password-file" ''
    #!${pkgs.stdenv.shell}

    set -euo pipefail

    if (! test -d "${passwdDir}"); then
      mkdir "${passwdDir}"
      chmod 755 "${passwdDir}"
    fi

    # Prevent world-readable password files, even temporarily.
    umask 077

    for f in ${builtins.toString (lib.mapAttrsToList (name: value: passwordFiles."${name}") cfg.loginAccounts)}; do
      if [ ! -f "$f" ]; then
        echo "Expected password hash file $f does not exist!"
        exit 1
      fi
    done

    cat <<EOF > ${passwdFile}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value:
      "${name}:${"$(head -n 1 ${passwordFiles."${name}"})"}::::::"
    ) cfg.loginAccounts)}
    EOF

    cat <<EOF > ${userdbFile}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value:
      "${name}:::::::"
        + (if lib.isString value.quota
              then "userdb_quota_rule=*:storage=${value.quota}"
              else "")
    ) cfg.loginAccounts)}
    EOF
  '';

  junkMailboxes = builtins.attrNames (lib.filterAttrs (n: v: v ? "specialUse" && v.specialUse == "Junk") cfg.mailboxes);
  junkMailboxNumber = builtins.length junkMailboxes;
  # The assertion garantees there is exactly one Junk mailbox.
  junkMailboxName = if junkMailboxNumber == 1 then builtins.elemAt junkMailboxes 0 else "";

  mkLdapSearchScope = scope: (
    if scope == "sub" then "subtree"
    else if scope == "one" then "onelevel"
    else scope
  );

in
{
  config = with cfg; lib.mkIf enable {
    assertions = [
      {
        assertion = junkMailboxNumber == 1;
        message = "nixos-mailserver requires exactly one dovecot mailbox with the 'special use' flag set to 'Junk' (${builtins.toString junkMailboxNumber} have been found)";
      }
    ];

    # for sieve-test. Shelling it in on demand usually doesnt' work, as it reads
    # the global config and tries to open shared libraries configured in there,
    # which are usually not compatible.
    environment.systemPackages = [
      pkgs.dovecot_pigeonhole
    ] ++ (lib.optional cfg.fullTextSearch.enable pkgs.dovecot_fts_xapian );

    services.dovecot2 = {
      enable = true;
      enableImap = enableImap || enableImapSsl;
      enablePop3 = enablePop3 || enablePop3Ssl;
      enablePAM = false;
      enableQuota = true;
      mailGroup = vmailGroupName;
      mailUser = vmailUserName;
      mailLocation = dovecotMaildir;
      sslServerCert = certificatePath;
      sslServerKey = keyPath;
      enableLmtp = true;
      # modules = [ pkgs.dovecot_pigeonhole ] ++ (lib.optional cfg.fullTextSearch.enable pkgs.dovecot_fts_xapian );
      mailPlugins.globally.enable = lib.optionals cfg.fullTextSearch.enable [ "fts" "fts_xapian" ];
      protocols = lib.optional cfg.enableManageSieve "sieve";

      pluginSettings = {
        sieve = "file:${cfg.sieveDirectory}/%u/scripts;active=${cfg.sieveDirectory}/%u/active.sieve";
        sieve_default = "file:${cfg.sieveDirectory}/%u/default.sieve";
        sieve_default_name = "default";
      };

      sieve = {
        extensions = [
          "fileinto"
        ];

        scripts.after = builtins.toFile "spam.sieve" ''
          require "fileinto";

          if header :is "X-Spam" "Yes" {
              fileinto "${junkMailboxName}";
              stop;
          }
        '';

        pipeBins = map lib.getExe [
          (pkgs.writeShellScriptBin "sa-learn-ham.sh"
            "exec ${pkgs.rspamd}/bin/rspamc -h /run/rspamd/worker-controller.sock learn_ham")
          (pkgs.writeShellScriptBin "sa-learn-spam.sh"
            "exec ${pkgs.rspamd}/bin/rspamc -h /run/rspamd/worker-controller.sock learn_spam")
        ];
      };

      imapsieve.mailbox = [
        {
          name = junkMailboxName;
          causes = [ "COPY" "APPEND" ];
          before = ./dovecot/imap_sieve/report-spam.sieve;
        }
        {
          name = "*";
          from = junkMailboxName;
          causes = [ "COPY" ];
          before = ./dovecot/imap_sieve/report-ham.sieve;
        }
      ];

      mailboxes = cfg.mailboxes;

      extraConfig = ''
        #Extra Config
        ${lib.optionalString debug ''
          mail_debug = yes
          auth_debug = yes
          verbose_ssl = yes
        ''}

        ${lib.optionalString (cfg.enableImap || cfg.enableImapSsl) ''
          service imap-login {
            inet_listener imap {
              ${if cfg.enableImap then ''
                port = 143
              '' else ''
                # see https://dovecot.org/pipermail/dovecot/2010-March/047479.html
                port = 0
              ''}
            }
            inet_listener imaps {
              ${if cfg.enableImapSsl then ''
                port = 993
                ssl = yes
              '' else ''
                # see https://dovecot.org/pipermail/dovecot/2010-March/047479.html
                port = 0
              ''}
            }
          }
        ''}
        ${lib.optionalString (cfg.enablePop3 || cfg.enablePop3Ssl) ''
          service pop3-login {
            inet_listener pop3 {
              ${if cfg.enablePop3 then ''
                port = 110
              '' else ''
                # see https://dovecot.org/pipermail/dovecot/2010-March/047479.html
                port = 0
              ''}
            }
            inet_listener pop3s {
              ${if cfg.enablePop3Ssl then ''
                port = 995
                ssl = yes
              '' else ''
                # see https://dovecot.org/pipermail/dovecot/2010-March/047479.html
                port = 0
              ''}
            }
          }
        ''}

        protocol imap {
          mail_max_userip_connections = ${toString cfg.maxConnectionsPerUser}
          mail_plugins = $mail_plugins imap_sieve
        }

        service imap {
	  vsz_limit = ${builtins.toString cfg.imapMemoryLimit} MB
	}

        protocol pop3 {
          mail_max_userip_connections = ${toString cfg.maxConnectionsPerUser}
        }

        mail_access_groups = ${vmailGroupName}
        ssl = required
        ssl_min_protocol = TLSv1.2
        ssl_prefer_server_ciphers = yes

        service lmtp {
          unix_listener dovecot-lmtp {
            group = ${postfixCfg.group}
            mode = 0600
            user = ${postfixCfg.user}
          }
	  vsz_limit = ${builtins.toString cfg.lmtpMemoryLimit} MB
        }

        service quota-status {
	  vsz_limit = ${builtins.toString cfg.quotaStatusMemoryLimit} MB
	}

        recipient_delimiter = ${cfg.recipientDelimiter}
        lmtp_save_to_detail_mailbox = ${cfg.lmtpSaveToDetailMailbox}

        protocol lmtp {
          mail_plugins = $mail_plugins sieve
        }

        passdb {
          driver = passwd-file
          args = ${passwdFile}
        }

        userdb {
          driver = passwd-file
          args = ${userdbFile}
          default_fields = uid=${builtins.toString cfg.vmailUID} gid=${builtins.toString cfg.vmailUID} home=${cfg.mailDirectory}
        }

        ${lib.optionalString cfg.ldap.enable ''
        passdb {
          driver = ldap
          args = ${ldapConfFile}
        }

        userdb {
          driver = ldap
          args = ${ldapConfFile}
          default_fields = home=/var/vmail/ldap/%u uid=${toString cfg.vmailUID} gid=${toString cfg.vmailUID}
        }
        ''}

        service auth {
          unix_listener auth {
            mode = 0660
            user = ${postfixCfg.user}
            group = ${postfixCfg.group}
          }
        }

        auth_mechanisms = plain login

        namespace inbox {
          separator = ${cfg.hierarchySeparator}
          inbox = yes
        }

        ${lib.optionalString cfg.fullTextSearch.enable ''
        plugin {
          plugin = fts fts_xapian
          fts = xapian
          fts_xapian = partial=${toString cfg.fullTextSearch.minSize} verbose=${bool2int cfg.debug}

          fts_autoindex = ${if cfg.fullTextSearch.autoIndex then "yes" else "no"}

          ${lib.strings.concatImapStringsSep "\n" (n: x: "fts_autoindex_exclude${if n==1 then "" else toString n} = ${x}") cfg.fullTextSearch.autoIndexExclude}

          fts_enforced = ${cfg.fullTextSearch.enforced}
        }

        service indexer-worker {
        ${lib.optionalString (cfg.fullTextSearch.memoryLimit != null) ''
          vsz_limit = ${toString (cfg.fullTextSearch.memoryLimit*1024*1024)}
        ''}
          process_limit = 0
        }
        ''}

        lda_mailbox_autosubscribe = yes
        lda_mailbox_autocreate = yes
      '';
    };

    systemd.services.dovecot2 = {
      preStart = ''
        ${genPasswdScript}
      '' + (lib.optionalString cfg.ldap.enable setPwdInLdapConfFile);
    };

    systemd.services.postfix.restartTriggers = [ genPasswdScript ] ++ (lib.optional cfg.ldap.enable [setPwdInLdapConfFile]);

    systemd.services.dovecot-fts-xapian-optimize = lib.mkIf (cfg.fullTextSearch.enable && cfg.fullTextSearch.maintenance.enable) {
      description = "Optimize dovecot indices for fts_xapian";
      requisite = [ "dovecot2.service" ];
      after = [ "dovecot2.service" ];
      startAt = cfg.fullTextSearch.maintenance.onCalendar;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.dovecot}/bin/doveadm fts optimize -A";
        PrivateDevices = true;
        PrivateNetwork = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectSystem = true;
        PrivateTmp = true;
      };
    };
    systemd.timers.dovecot-fts-xapian-optimize = lib.mkIf (cfg.fullTextSearch.enable && cfg.fullTextSearch.maintenance.enable && cfg.fullTextSearch.maintenance.randomizedDelaySec != 0) {
      timerConfig = {
        RandomizedDelaySec = cfg.fullTextSearch.maintenance.randomizedDelaySec;
      };
    };
  };
}
