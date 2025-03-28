Add Radicale
============

Configuration by @dotlambda

Starting with Radicale 3 (first introduced in NixOS 20.09) the traditional
crypt passwords are no longer supported.  Instead bcrypt passwords
have to be used. These can still be generated using `mkpasswd -m bcrypt`.

.. code:: nix

   { config, pkgs, lib, ... }:

   with lib;

   let
     mailAccounts = config.mailserver.loginAccounts;
     htpasswd = pkgs.writeText "radicale.users" (concatStrings
       (flip mapAttrsToList mailAccounts (mail: user:
         mail + ":" + user.hashedPassword + "\n"
       ))
     );

   in {
     services.radicale = {
       enable = true;
       settings = {
         auth = {
           type = "htpasswd";
           htpasswd_filename = "${htpasswd}";
           htpasswd_encryption = "bcrypt";
         };
       };
     };

     services.nginx = {
       enable = true;
       virtualHosts = {
         "cal.example.com" = {
           forceSSL = true;
           enableACME = true;
           locations."/" = {
             proxyPass = "http://localhost:5232/";
             extraConfig = ''
               proxy_set_header  X-Script-Name /;
               proxy_set_header  X-Forwarded-For $proxy_add_x_forwarded_for;
               proxy_pass_header Authorization;
             '';
           };
         };
       };
     };

     networking.firewall.allowedTCPPorts = [ 80 443 ];
   }
