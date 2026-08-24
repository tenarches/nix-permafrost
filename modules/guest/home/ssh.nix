{
  flake.modules.homeManager.agent-ssh =
    { config, lib, ... }:

    {
      options.permafrost.ssh.dropins = lib.mkOption {
        type = lib.types.attrsOf lib.types.lines;
        default = { };
        example = lib.literalExpression ''
          {
            "10-example" = '''
              Host git.example.com
                Port 2222
            ''';
          }
        '';
        description = ''
          Site-specific ssh_config fragments, each written to
          `~/.ssh/config.d/<name>.conf`.

          Home Manager emits the `Include` directive above the `Host` blocks it
          generates, and ssh_config takes the first value it obtains for a keyword,
          so a drop-in overrides the fleet-wide defaults below it. A fork that does
          not want a fragment simply drops its import.
        '';
      };

      config = {
        home.file = lib.mapAttrs' (
          name: text: lib.nameValuePair ".ssh/config.d/${name}.conf" { inherit text; }
        ) config.permafrost.ssh.dropins;

        programs.ssh = {
          enable = true;

          # Home Manager's legacy `Host *` defaults contradict the block below
          # (ForwardAgent no, ServerAliveInterval 0, a real known_hosts file) and
          # leaving it on emits a deprecation warning regardless. Declare the
          # catch-all here instead.
          enableDefaultConfig = false;

          # Relative to ~/.ssh. A glob matching nothing is not an error, so this is
          # safe when permafrost.ssh.dropins is empty.
          includes = [ "config.d/*.conf" ];

          # These guests are disposable and rebuilt from scratch on every boot, so
          # host keys are expected to change and there is nothing worth persisting
          # in a known_hosts file.
          settings."*" = {
            StrictHostKeyChecking = "no";
            UserKnownHostsFile = "/dev/null";
            ServerAliveInterval = 150;
            ServerAliveCountMax = 2;
            ForwardAgent = true;
            LogLevel = "ERROR";
          };
        };
      };
    };
}
