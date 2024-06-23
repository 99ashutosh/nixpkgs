{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.caddy;

  virtualHosts = attrValues cfg.virtualHosts;
  acmeVHosts = filter (hostOpts: hostOpts.useACMEHost != null) virtualHosts;

  mkVHostConf = hostOpts:
    let
      sslCertDir = config.security.acme.certs.${hostOpts.useACMEHost}.directory;
    in
      ''
        ${hostOpts.hostName} ${concatStringsSep " " hostOpts.serverAliases} {
          ${optionalString (hostOpts.listenAddresses != [ ]) "bind ${concatStringsSep " " hostOpts.listenAddresses}"}
          ${optionalString (hostOpts.useACMEHost != null) "tls ${sslCertDir}/cert.pem ${sslCertDir}/key.pem"}
          log {
            ${hostOpts.logFormat}
          }

          ${hostOpts.extraConfig}
        }
      '';

  settingsFormat = pkgs.formats.json { };

  configFile =
    if cfg.settings != { } then
      settingsFormat.generate "caddy.json" cfg.settings
    else
      let
        Caddyfile = pkgs.writeTextDir "Caddyfile" ''
          {
            ${cfg.globalConfig}
          }
          ${cfg.extraConfig}
          ${concatMapStringsSep "\n" mkVHostConf virtualHosts}
        '';

        Caddyfile-formatted = pkgs.runCommand "Caddyfile-formatted" { nativeBuildInputs = [ cfg.package ]; } ''
          mkdir -p $out
          cp --no-preserve=mode ${Caddyfile}/Caddyfile $out/Caddyfile
          caddy fmt --overwrite $out/Caddyfile
        '';
      in
      "${if pkgs.stdenv.buildPlatform == pkgs.stdenv.hostPlatform then Caddyfile-formatted else Caddyfile}/Caddyfile";

  etcConfigFile = "caddy/caddy_config";

  configPath = "/etc/${etcConfigFile}";

  acmeHosts = unique (catAttrs "useACMEHost" acmeVHosts);

  mkCertOwnershipAssertion = import ../../../security/acme/mk-cert-ownership-assertion.nix;
in
{
  imports = [
    (mkRemovedOptionModule [ "services" "caddy" "agree" ] "this option is no longer necessary for Caddy 2")
    (mkRenamedOptionModule [ "services" "caddy" "ca" ] [ "services" "caddy" "acmeCA" ])
    (mkRenamedOptionModule [ "services" "caddy" "config" ] [ "services" "caddy" "extraConfig" ])
  ];

  # interface
  options.services.caddy = {
    enable = mkEnableOption "Caddy web server";

    user = mkOption {
      default = "caddy";
      type = types.str;
      description = ''
        User account under which caddy runs.

        ::: {.note}
        If left as the default value this user will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the user exists before the Caddy service starts.
        :::
      '';
    };

    group = mkOption {
      default = "caddy";
      type = types.str;
      description = ''
        Group account under which caddy runs.

        ::: {.note}
        If left as the default value this user will automatically be created
        on system activation, otherwise you are responsible for
        ensuring the user exists before the Caddy service starts.
        :::
      '';
    };

    package = mkPackageOption pkgs "caddy" { };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/caddy";
      description = ''
        The data directory for caddy.

        ::: {.note}
        If left as the default value this directory will automatically be created
        before the Caddy server starts, otherwise you are responsible for ensuring
        the directory exists with appropriate ownership and permissions.

        Caddy v2 replaced `CADDYPATH` with XDG directories.
        See <https://caddyserver.com/docs/conventions#file-locations>.
        :::
      '';
    };

    logDir = mkOption {
      type = types.path;
      default = "/var/log/caddy";
      description = ''
        Directory for storing Caddy access logs.

        ::: {.note}
        If left as the default value this directory will automatically be created
        before the Caddy server starts, otherwise the sysadmin is responsible for
        ensuring the directory exists with appropriate ownership and permissions.
        :::
      '';
    };

    logFormat = mkOption {
      type = types.lines;
      default = ''
        level ERROR
      '';
      example = literalExpression ''
        mkForce "level INFO";
      '';
      description = ''
        Configuration for the default logger. See
        <https://caddyserver.com/docs/caddyfile/options#log>
        for details.
      '';
    };

    configFile = mkOption {
      type = types.path;
      default = configFile;
      defaultText = "A Caddyfile automatically generated by values from services.caddy.*";
      example = literalExpression ''
        pkgs.writeText "Caddyfile" '''
          example.com

          root * /var/www/wordpress
          php_fastcgi unix//run/php/php-version-fpm.sock
          file_server
        ''';
      '';
      description = ''
        Override the configuration file used by Caddy. By default,
        NixOS generates one automatically.

        The configuration file is exposed at {file}`${configPath}`.
      '';
    };

    adapter = mkOption {
      default = if ((cfg.configFile != configFile) || (builtins.baseNameOf cfg.configFile) == "Caddyfile") then "caddyfile" else null;
      defaultText = literalExpression ''
        if ((cfg.configFile != configFile) || (builtins.baseNameOf cfg.configFile) == "Caddyfile") then "caddyfile" else null
      '';
      example = literalExpression "nginx";
      type = with types; nullOr str;
      description = ''
        Name of the config adapter to use.
        See <https://caddyserver.com/docs/config-adapters>
        for the full list.

        If `null` is specified, the `--adapter` argument is omitted when
        starting or restarting Caddy. Notably, this allows specification of a
        configuration file in Caddy's native JSON format, as long as the
        filename does not start with `Caddyfile` (in which case the `caddyfile`
        adapter is implicitly enabled). See
        <https://caddyserver.com/docs/command-line#caddy-run> for details.

        ::: {.note}
        Any value other than `null` or `caddyfile` is only valid when providing
        your own `configFile`.
        :::
      '';
    };

    resume = mkOption {
      default = false;
      type = types.bool;
      description = ''
        Use saved config, if any (and prefer over any specified configuration passed with `--config`).
      '';
    };

    globalConfig = mkOption {
      type = types.lines;
      default = "";
      example = ''
        debug
        servers {
          protocol {
            experimental_http3
          }
        }
      '';
      description = ''
        Additional lines of configuration appended to the global config section
        of the `Caddyfile`.

        Refer to <https://caddyserver.com/docs/caddyfile/options#global-options>
        for details on supported values.
      '';
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      example = ''
        example.com {
          encode gzip
          log
          root /srv/http
        }
      '';
      description = ''
        Additional lines of configuration appended to the automatically
        generated `Caddyfile`.
      '';
    };

    virtualHosts = mkOption {
      type = with types; attrsOf (submodule (import ./vhost-options.nix { inherit cfg; }));
      default = {};
      example = literalExpression ''
        {
          "hydra.example.com" = {
            serverAliases = [ "www.hydra.example.com" ];
            extraConfig = '''
              encode gzip
              root /srv/http
            ''';
          };
        };
      '';
      description = ''
        Declarative specification of virtual hosts served by Caddy.
      '';
    };

    acmeCA = mkOption {
      default = null;
      example = "https://acme-v02.api.letsencrypt.org/directory";
      type = with types; nullOr str;
      description = ''
        ::: {.note}
        Sets the [`acme_ca` option](https://caddyserver.com/docs/caddyfile/options#acme-ca)
        in the global options block of the resulting Caddyfile.
        :::

        The URL to the ACME CA's directory. It is strongly recommended to set
        this to `https://acme-staging-v02.api.letsencrypt.org/directory` for
        Let's Encrypt's [staging endpoint](https://letsencrypt.org/docs/staging-environment/)
        while testing or in development.

        Value `null` should be prefered for production setups,
        as it omits the `acme_ca` option to enable
        [automatic issuer fallback](https://caddyserver.com/docs/automatic-https#issuer-fallback).
      '';
    };

    email = mkOption {
      default = null;
      type = with types; nullOr str;
      description = ''
        Your email address. Mainly used when creating an ACME account with your
        CA, and is highly recommended in case there are problems with your
        certificates.
      '';
    };

    enableReload = mkOption {
      default = true;
      type = types.bool;
      description = ''
        Reload Caddy instead of restarting it when configuration file changes.

        Note that enabling this option requires the [admin API](https://caddyserver.com/docs/caddyfile/options#admin)
        to not be turned off.

        If you enable this option, consider setting [`grace_period`](https://caddyserver.com/docs/caddyfile/options#grace-period)
        to a non-infinite value in {option}`services.caddy.globalConfig`
        to prevent Caddy waiting for active connections to finish,
        which could delay the reload essentially indefinitely.
      '';
    };

    settings = mkOption {
      type = settingsFormat.type;
      default = {};
      description = ''
        Structured configuration for Caddy to generate a Caddy JSON configuration file.
        See <https://caddyserver.com/docs/json/> for available options.

        ::: {.warning}
        Using a [Caddyfile](https://caddyserver.com/docs/caddyfile) instead of a JSON config is highly recommended by upstream.
        There are only very few exception to this.

        Please use a Caddyfile via {option}`services.caddy.configFile`, {option}`services.caddy.virtualHosts` or
        {option}`services.caddy.extraConfig` with {option}`services.caddy.globalConfig` instead.
        :::

        ::: {.note}
        Takes presence over most `services.caddy.*` options, such as {option}`services.caddy.configFile` and {option}`services.caddy.virtualHosts`, if specified.
        :::
      '';
    };
  };

  # implementation
  config = mkIf cfg.enable {

    assertions = [
      { assertion = cfg.configFile == configFile -> cfg.adapter == "caddyfile" || cfg.adapter == null;
        message = "To specify an adapter other than 'caddyfile' please provide your own configuration via `services.caddy.configFile`";
      }
    ] ++ map (name: mkCertOwnershipAssertion {
      inherit (cfg) group user;
      cert = config.security.acme.certs.${name};
      groups = config.users.groups;
    }) acmeHosts;

    services.caddy.globalConfig = ''
      ${optionalString (cfg.email != null) "email ${cfg.email}"}
      ${optionalString (cfg.acmeCA != null) "acme_ca ${cfg.acmeCA}"}
      log {
        ${cfg.logFormat}
      }
    '';

    # https://github.com/quic-go/quic-go/wiki/UDP-Buffer-Sizes
    boot.kernel.sysctl."net.core.rmem_max" = mkDefault 2500000;
    boot.kernel.sysctl."net.core.wmem_max" = mkDefault 2500000;

    systemd.packages = [ cfg.package ];
    systemd.services.caddy = {
      wants = map (hostOpts: "acme-finished-${hostOpts.useACMEHost}.target") acmeVHosts;
      after = map (hostOpts: "acme-selfsigned-${hostOpts.useACMEHost}.service") acmeVHosts;
      before = map (hostOpts: "acme-${hostOpts.useACMEHost}.service") acmeVHosts;

      wantedBy = [ "multi-user.target" ];
      startLimitIntervalSec = 14400;
      startLimitBurst = 10;
      reloadTriggers = optional cfg.enableReload cfg.configFile;

      serviceConfig = let
        runOptions = ''--config ${configPath} ${optionalString (cfg.adapter != null) "--adapter ${cfg.adapter}"}'';
      in {
        # Override the `ExecStart` line from upstream's systemd unit file by our own:
        # https://www.freedesktop.org/software/systemd/man/systemd.service.html#ExecStart=
        # If the empty string is assigned to this option, the list of commands to start is reset, prior assignments of this option will have no effect.
        ExecStart = [ "" ''${cfg.package}/bin/caddy run ${runOptions} ${optionalString cfg.resume "--resume"}'' ];
        # Validating the configuration before applying it ensures we’ll get a proper error that will be reported when switching to the configuration
        ExecReload = [ "" ] ++ lib.optional cfg.enableReload "${lib.getExe cfg.package} reload ${runOptions} --force";
        User = cfg.user;
        Group = cfg.group;
        ReadWritePaths = [ cfg.dataDir ];
        StateDirectory = mkIf (cfg.dataDir == "/var/lib/caddy") [ "caddy" ];
        LogsDirectory = mkIf (cfg.logDir == "/var/log/caddy") [ "caddy" ];
        Restart = "on-failure";
        RestartPreventExitStatus = 1;
        RestartSec = "5s";

        # TODO: attempt to upstream these options
        NoNewPrivileges = true;
        PrivateDevices = true;
        ProtectHome = true;
      };
    };

    users.users = optionalAttrs (cfg.user == "caddy") {
      caddy = {
        group = cfg.group;
        uid = config.ids.uids.caddy;
        home = cfg.dataDir;
      };
    };

    users.groups = optionalAttrs (cfg.group == "caddy") {
      caddy.gid = config.ids.gids.caddy;
    };

    security.acme.certs =
      let
        certCfg = map (useACMEHost: nameValuePair useACMEHost {
          group = mkDefault cfg.group;
          reloadServices = [ "caddy.service" ];
        }) acmeHosts;
      in
        listToAttrs certCfg;

    environment.etc.${etcConfigFile}.source = cfg.configFile;
  };
}
