# overlays/python-mcp.nix
# Centralized Python package overrides for MCP dependency chain

_final: prev: {
  pythonPackagesExtensions = prev.pythonPackagesExtensions ++ [
    (pySelf: pyPrev: {
      fastmcp = pyPrev.fastmcp.overridePythonAttrs {
        doCheck = false;
      };
      # fakeredis requires lupa for Lua scripting; disabling flaky tests
      # Patching fakeredis to handle lupa import more gracefully in Nix
      fakeredis = pyPrev.fakeredis.overridePythonAttrs (old: {
        doCheck = false;
        propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [
          pySelf.lupa
        ];
        postPatch = (old.postPatch or "") + ''
          sed -i 's/import_module(__LUA_RUNTIMES_MAP\[LUA_VERSION\])/import_module("lupa")/' fakeredis/commands_mixins/scripting_mixin.py
        '';
      });
      # pydocket uses fakeredis and needs to ensure lupa is available
      pydocket = pyPrev.pydocket.overridePythonAttrs (old: {
        doCheck = false;
        propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [
          pySelf.lupa
        ];
      });
      mcp-nixos = pyPrev.mcp-nixos.overridePythonAttrs (old: {
        propagatedBuildInputs = (old.propagatedBuildInputs or [ ]) ++ [
          pySelf.lupa
        ];
      });
    })
  ];
}
