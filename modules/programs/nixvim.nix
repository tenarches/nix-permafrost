_:

{
  programs.nixvim = {
    enable = true;
    defaultEditor = true;

    viAlias = true;
    vimAlias = true;

    # Options
    opts = {
      background = "dark";
      shiftwidth = 2;
      tabstop = 2;
      expandtab = true;
      smartindent = true;
      cursorline = true;
      scrolloff = 8;
      termguicolors = true;
      mouse = "a";
      number = false;
      relativenumber = false;
    };

    # Clipboard
    clipboard = {
      register = "unnamedplus";
      providers.wl-copy.enable = true;
    };

    # Keymaps
    keymaps = [
      {
        mode = [
          "n"
          "v"
          "i"
          "c"
        ];
        key = "<RightMouse>";
        action = "<C-R>+";
        options.desc = "Paste from system clipboard";
      }
      {
        mode = "n";
        key = "<C-d>";
        action = "<C-d>zz";
      }
      {
        mode = "n";
        key = "<C-u>";
        action = "<C-u>zz";
      }
      {
        mode = [
          "n"
          "v"
        ];
        key = "<C-j>";
        action = "8j";
      }
      {
        mode = [
          "n"
          "v"
        ];
        key = "<C-k>";
        action = "8k";
      }
    ];

    plugins = {
      # LSP
      lsp = {
        enable = true;
        servers = {
          nixd.enable = true;
          terraformls.enable = true;
          yamlls.enable = true;
          jsonls.enable = true;
          taplo.enable = true;
          bashls.enable = true;
        };
      };

      # Completion
      cmp = {
        enable = true;
        autoEnableSources = true;
        settings = {
          sources = [
            { name = "nvim_lsp"; }
            { name = "path"; }
            { name = "buffer"; }
            { name = "luasnip"; }
          ];
          mapping = {
            "<C-Space>" = "cmp.mapping.complete()";
            "<Tab>" = "cmp.mapping(cmp.mapping.select_next_item(), {'i', 's'})";
            "<S-Tab>" = "cmp.mapping(cmp.mapping.select_prev_item(), {'i', 's'})";
            "<CR>" = "cmp.mapping.confirm({ select = true })";
            "<C-e>" = "cmp.mapping.close()";
            "<C-d>" = "cmp.mapping.scroll_docs(-4)";
            "<C-f>" = "cmp.mapping.scroll_docs(4)";
          };
        };
      };
      cmp-nvim-lsp.enable = true;
      cmp-buffer.enable = true;
      cmp-path.enable = true;
      cmp_luasnip.enable = true;
      luasnip.enable = true;

      # Treesitter
      treesitter = {
        enable = true;
        settings = {
          highlight.enable = true;
          indent.enable = true;
        };
      };

      # Other plugins
      telescope.enable = true;
      lualine.enable = true;
      neo-tree.enable = true;
      gitsigns.enable = true;
      which-key.enable = true;
      web-devicons.enable = true;
    };

    # Colorscheme
    colorschemes.nightfox = {
      enable = true;
      flavor = "carbonfox";
    };
  };
}
