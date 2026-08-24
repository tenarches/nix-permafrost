{
  flake.modules.nixos.host-secrets =
    {
      pkgs,
      inputs,
      ...
    }:

    {
      imports = [
        inputs.sops-nix.nixosModules.sops
      ];

      # TPM-protected age key setup as recommended in SECRETS_MANAGEMENT.md
      # This oneshot service decrypts the age key from TPM into /var/lib/sops-nix/key.txt
      systemd.services.sops-age-key-prep = {
        description = "Prepare SOPS age key from TPM";
        before = [ "sops-nix.service" ];
        wantedBy = [ "sops-nix.service" ];
        serviceConfig = {
          Type = "oneshot";
          LoadCredentialEncrypted = [
            "sops-age-key:/etc/credstore.encrypted/sops-age-key.cred"
          ];
          ExecStart = pkgs.writeShellScript "prep-age-key" ''
            install -dm 0700 /var/lib/sops-nix
            install -m 0600 $CREDENTIALS_DIRECTORY/sops-age-key /var/lib/sops-nix/key.txt
          '';
        };
      };

      sops = {
        defaultSopsFile = ../../secrets/agents.yaml;
        age.keyFile = "/var/lib/sops-nix/key.txt";

        secrets = {
          "anthropic-api-key" = {
            owner = "root";
            # Path: /run/secrets/anthropic-api-key
          };
          "google-api-key" = {
            owner = "root";
          };
        };
      };
    };
}
