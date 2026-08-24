{
  flake.modules.nixos.guest-theme =
    { pkgs, ... }:
    {
      # Fleet-wide palette, mirroring the workstation configuration in nix-nexus so
      # an agent's terminal looks the same as the one driving it.
      stylix = {
        enable = true;

        # Opt-in targets only. The guests are headless terminals, so almost nothing
        # stylix knows how to theme is present; the targets that are wanted are
        # enabled per-user in guest/home/environment.nix.
        autoEnable = false;

        # Keeps the Rust palette generator out of the closure entirely — with an
        # explicit base16Scheme there is nothing for it to derive.
        image = null;

        polarity = "dark";
        base16Scheme = "${pkgs.base16-schemes}/share/themes/ayu-dark.yaml";
        override.base0D = "39BAE6";

        fonts = {
          monospace = {
            package = pkgs.nerd-fonts.jetbrains-mono;
            name = "JetBrainsMono Nerd Font";
          };
          sansSerif = {
            package = pkgs.noto-fonts;
            name = "Noto Sans";
          };
          serif = {
            package = pkgs.noto-fonts;
            name = "Noto Serif";
          };
          emoji = {
            package = pkgs.noto-fonts-color-emoji;
            name = "Noto Color Emoji";
          };
          sizes = {
            terminal = 14;
            applications = 12;
            desktop = 10;
            popups = 10;
          };
        };

        cursor = {
          package = pkgs.adwaita-icon-theme;
          name = "Adwaita";
          size = 24;
        };
      };
    };
}
