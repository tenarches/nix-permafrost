{ config, lib, ... }:

let
  cfg = config.microvm;
  isCLH = cfg.hypervisor == "cloud-hypervisor";
  hasCreds = cfg.credentialFiles != { };
in
{
  config = lib.mkIf (isCLH && hasCreds) {

    assertions = [
      {
        assertion = (cfg.cloud-hypervisor.platformOEMStrings or [ ]) == [ ];
        message = ''
          microvm: credentialFiles workaround conflicts with
          cloud-hypervisor.platformOEMStrings. Both map to --platform
          oem_string=[...] and cloud-hypervisor accepts only one
          --platform flag. Move any static OEM strings into extraArgsScript
          manually, or drop platformOEMStrings.
        '';
      }
    ];

    microvm.extraArgsScript =
      let
        credEntries = lib.mapAttrsToList (name: path: { inherit name path; }) cfg.credentialFiles;

        readCredsScript = lib.concatMapStrings (
          { name, path }:
          ''
            if [ ! -r "${path}" ]; then
              echo "microvm-credential-fix: cannot read '${path}' for credential '${name}'" >&2
              exit 1
            fi
            _val=$(cat "${path}")
            _oem_parts="''${_oem_parts:+''${_oem_parts},}io.systemd.credential:${name}=''${_val}"
          ''
        ) credEntries;
      in
      ''
        _oem_parts=""
        ${readCredsScript}
        printf -- '--platform oem_string=[%s]' "$_oem_parts"
      '';
  };
}
