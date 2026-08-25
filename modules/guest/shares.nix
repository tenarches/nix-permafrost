{
  # The host dot directories mapped into the guest.
  #
  # An option rather than a spec field, so each harness declares only its own
  # and the module system merges them. Adding a harness therefore adds its
  # shares without anything central being edited.
  #
  # What is deliberately *not* here is as important as what is. The host's
  # ~/workspace is never mapped: the guest gets a private ephemeral workspace on
  # its own home volume, so nothing an agent checks out or builds reaches the
  # host unless it is pushed somewhere. Nor is ~/.dsh mapped whole — that harness
  # shares three data directories beneath it and keeps the rest ephemeral,
  # because its configuration is rendered from Nix on every boot. See the
  # permafrost.shares block in modules/harness/dsh.nix.
  flake.modules.nixos.guest-shares =
    { lib, config, ... }:
    let
      inherit (config.permafrost) shares;
    in
    {
      options.permafrost.shares = lib.mkOption {
        default = [ ];
        description = ''
          Host directories carried into the guest over virtiofs, so an agent's
          auth and history survive a boot of a guest that is otherwise wiped
          every time.
        '';
        example = lib.literalExpression ''
          [
            { host = ".claude"; guest = ".claude"; }
            { host = ".config/claude"; guest = ".claude-config"; link = ".claude.json"; }
          ]
        '';
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              host = lib.mkOption {
                type = lib.types.str;
                description = "Path relative to the launching user's home on the host.";
              };
              guest = lib.mkOption {
                type = lib.types.str;
                description = ''
                  Path relative to /home/agent. Also the name under
                  /mnt/persist, where the share is actually mounted, and the
                  input to the virtiofs tag — so it must be unique.
                '';
              };
              link = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  An extra symlink into the share, for a harness that wants a
                  single file at a path of its own rather than the directory.
                  `~/<link>` resolves to `/mnt/persist/<guest>/<basename link>`.
                '';
              };
            };
          }
        );
      };

      # Mounting a share into a directory that is itself on the ephemeral home
      # volume would hide whatever the harness expects to find there, so the
      # mount lands under /mnt/persist and is symlinked into place instead.
      config.systemd.tmpfiles.rules =
        map (s: "d /mnt/persist/${s.guest} 0700 agent users - -") shares
        ++ map (s: "L+ /home/agent/${s.guest} - - - - /mnt/persist/${s.guest}") shares
        ++ lib.concatMap (
          s:
          lib.optional (
            s.link != null
          ) "L+ /home/agent/${s.link} - - - - /mnt/persist/${s.guest}/${builtins.baseNameOf s.link}"
        ) shares;
    };
}
