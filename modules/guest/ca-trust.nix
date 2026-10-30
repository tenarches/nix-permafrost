{
  # Trust for the homelab's internal CA, so the guest can reach the gateway over
  # https (permafrost.inference.baseUrl, permafrost.mcp.gatewayUrl).
  #
  # certs/int_cert.crt is the public intermediate plus root, the same file
  # nix-nexus carries. security.pki.certificateFiles puts it in the system
  # bundle, which curl and most tools read. Node ignores that bundle and uses
  # its own, so the bundle is also named in NODE_EXTRA_CA_CERTS for pi, dsh and
  # the other Node harnesses. dsh's user service gets the variable explicitly;
  # see harness/dsh.nix.
  flake.modules.nixos.guest-ca-trust = {
    security.pki.certificateFiles = [ ../../certs/int_cert.crt ];
    environment.variables.NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-certificates.crt";
  };
}
