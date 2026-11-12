{ lib, ... }:

let
  slots = import ../_lib/slots.nix;

  # An address or a CIDR, v4 or v6. The text goes into the nft ruleset, so the
  # type allows nothing but digits, hex, dots, colons and one prefix length.
  addressType = lib.types.strMatching "[0-9a-fA-F:.]+(/[0-9]+)?";
in
{
  # What a factory slot may reach on the network.
  #
  # A slot reads untrusted text and runs the commands that text asks for, so a
  # slot must not reach the LAN, the other slots, or the services of the guest.
  # One nftables table in the output hook decides by the uid of the socket
  # owner. Every slot starts in the default profile, and the helper in
  # netctl.nix moves a slot between profiles by moving its uid between sets.
  # Nothing is stored: after a reboot every slot is in the default profile again.
  #
  # What a slot may reach, in the order the rules run:
  #
  # - Answers on connections that began from outside (a listener of the slot).
  # - The declared resolvers and the local resolved stub, port 53 only.
  # - Nothing on the guest itself: not loopback, not the guest address. nftables
  #   cannot see who owns a listening socket, so this closes slot to slot too,
  #   and a slot cannot reach its own dev server on localhost
  #   (`slotLoopback = "allow"` takes the rule out).
  # - The internal list: addresses and ports that every profile may reach.
  # - Its profile: the LAN hosts and ports the profile names, and the internet,
  #   which is every public address on the ports of the profile (80 and 443).
  # - Nothing else. The reject is an ICMP error (`icmpx admin-prohibited`), and
  #   a TCP reset for TCP over v6, so a connect fails at once and a tool does
  #   not wait for a timeout. The errno is EHOSTUNREACH for v4 TCP and
  #   ECONNREFUSED for v6 TCP, and EPERM or ECONNREFUSED for UDP.
  #
  # The rules are by uid and destination, with no `ct state established` shortcut,
  # so a change of profile applies to the next packet of an open connection too.
  #
  # Two more groups of sockets are confined, because both would be a way round
  # the profile of a slot. The Nix build users (group nixbld) run the fetch of a
  # fixed-output derivation with network access, and a slot may start one, so
  # they get the internal list and the public ports, never a LAN host. The
  # netctl login gets the internal list only. Everyone else is not filtered:
  # root, the daemons, `agent` and `adurable` fall through to the accept policy.
  # A LAN profile does not reach builds: a fetch inside `nix build` from a LAN
  # host fails.
  #
  # Reserved ranges are not "the internet". TEST-NET and 2001:db8::/32 are not
  # listed, so they count as public. The VM check uses 203.0.113.0/24 as the
  # internet for that reason. 100.64.0.0/10 is listed, because tailscale and
  # carrier NAT live there: a deployment that needs a tailnet host adds it to
  # `internal` or to a LAN profile.
  #
  # Names are not resolved by nftables, which would fail the whole load when the
  # lookup fails before the network is up. The internal list is addresses.
  #
  # Not closed (the table does not see them): AF_VSOCK to the host, unix
  # sockets (abstract ones too), /tmp and the Nix store are shared between all
  # accounts. DNS query names leave through the declared resolver. The way to
  # close these is one network namespace and one private /tmp for each slot job.
  flake.modules.nixos.guest-network-egress =
    { config, ... }:

    let
      cfg = config.permafrost.network;
      slotCfg = config.permafrost.slots;
      isV6 = lib.hasInfix ":";
      v4 = lib.filter (a: !isV6 a);
      v6 = lib.filter isV6;
      profileNames = lib.attrNames cfg.profiles;

      list = lib.concatStringsSep ", ";
      set =
        {
          name,
          type,
          interval ? false,
          elements ? [ ],
        }:
        "set ${name} { type ${type}; ${lib.optionalString interval "flags interval; "}${
          lib.optionalString (elements != [ ]) "elements = { ${list elements} }; "
        }}";

      # One element of a concatenation set for each address and port.
      pairs = entries: lib.concatMap (e: map (port: "${e.address} . ${toString port}") e.ports) entries;
      internalEntries = lib.mapAttrsToList (_: e: {
        inherit (e) addresses allPorts;
        ports = e.tcpPorts;
      }) cfg.internal;
      internalPairs =
        pick:
        lib.concatMap (
          e:
          lib.optionals (!e.allPorts) (
            pairs (
              map (address: {
                inherit address;
                inherit (e) ports;
              }) (pick e.addresses)
            )
          )
        ) internalEntries;
      internalAll = pick: lib.concatMap (e: lib.optionals e.allPorts (pick e.addresses)) internalEntries;

      lanEntries = profile: cfg.profiles.${profile}.lan;
      lanPairs = pick: profile: pairs (lib.filter (e: pick [ e.address ] != [ ]) (lanEntries profile));

      first = slots.uid slotCfg 1;
      last = slots.uid slotCfg slotCfg.count;
      allUids = map (slots.uid slotCfg) (lib.range 1 slotCfg.count);

      sets = [
        (set {
          name = "slot_uids";
          type = "uid";
          interval = true;
          elements = [ "${toString first}-${toString last}" ];
        })
        (set {
          name = "netctl_uids";
          type = "uid";
          elements = [ (toString slots.netctl.uid) ];
        })
        (set {
          name = "resolvers4";
          type = "ipv4_addr";
          interval = true;
          elements = v4 cfg.resolvers;
        })
        (set {
          name = "resolvers6";
          type = "ipv6_addr";
          interval = true;
          elements = v6 cfg.resolvers;
        })
        (set {
          name = "internal4_all";
          type = "ipv4_addr";
          interval = true;
          elements = internalAll v4;
        })
        (set {
          name = "internal6_all";
          type = "ipv6_addr";
          interval = true;
          elements = internalAll v6;
        })
        (set {
          name = "internal4_ports";
          type = "ipv4_addr . inet_service";
          interval = true;
          elements = internalPairs v4;
        })
        (set {
          name = "internal6_ports";
          type = "ipv6_addr . inet_service";
          interval = true;
          elements = internalPairs v6;
        })
        (set {
          name = "reserved4";
          type = "ipv4_addr";
          interval = true;
          elements = cfg.reservedRanges.v4;
        })
        (set {
          name = "reserved6";
          type = "ipv6_addr";
          interval = true;
          elements = cfg.reservedRanges.v6;
        })
      ]
      ++ lib.concatMap (profile: [
        # No `flags interval`: nft cannot delete one uid out of a range, and the
        # helper moves uids one at a time. Every slot starts in the default
        # profile, and the others start empty.
        (set {
          name = slots.uidSet profile;
          type = "uid";
          elements = lib.optionals (profile == cfg.defaultProfile) (map toString allUids);
        })
        (set {
          name = "lan_${slots.profileId profile}4";
          type = "ipv4_addr . inet_service";
          interval = true;
          elements = lanPairs v4 profile;
        })
        (set {
          name = "lan_${slots.profileId profile}6";
          type = "ipv6_addr . inet_service";
          interval = true;
          elements = lanPairs v6 profile;
        })
      ]) profileNames;

      # `icmpx admin-prohibited` fails a v4 connect at once with EHOSTUNREACH. For
      # TCP over v6 the first ICMPv6 error does not reach the socket (seen in the
      # VM check, and in a network namespace), and the connect fails one second
      # later, at the retransmit of the SYN, with EACCES. A TCP reset fails it at
      # once with ECONNREFUSED, so v6 TCP takes that. Everything else, UDP too,
      # gets the ICMP error, which arrives at once.
      reject = ''
        meta nfproto ipv6 meta l4proto tcp reject with tcp reset
        reject with icmpx type admin-prohibited
      '';
      stub = "ip daddr 127.0.0.53 meta l4proto { tcp, udp } th dport 53 accept";
      local = ''
        meta nfproto ipv6 meta l4proto tcp fib daddr type local reject with tcp reset
        fib daddr type local reject with icmpx type admin-prohibited
      '';

      # The rules that every confined group shares, after the local checks.
      shared = ''
        ip daddr @resolvers4 meta l4proto { tcp, udp } th dport 53 accept
        ip6 daddr @resolvers6 meta l4proto { tcp, udp } th dport 53 accept
        ip daddr @internal4_all accept
        ip6 daddr @internal6_all accept
        ip daddr . tcp dport @internal4_ports accept
        ip6 daddr . tcp dport @internal6_ports accept
      '';

      publicRule =
        ports:
        lib.optionalString (ports != [ ]) ''
          ip daddr != @reserved4 tcp dport { ${list (map toString ports)} } accept
          ip6 daddr != @reserved6 tcp dport { ${list (map toString ports)} } accept
        '';

      profileChain =
        profile:
        let
          p = cfg.profiles.${profile};
          id = slots.profileId profile;
        in
        ''
          chain profile_${id} {
            ip daddr . tcp dport @lan_${id}4 accept
            ip6 daddr . tcp dport @lan_${id}6 accept
            ${lib.optionalString p.internet.enable (publicRule p.internet.tcpPorts)}
          }
        '';

      table = ''
        ${lib.concatStringsSep "\n" sets}

        ${lib.concatMapStrings profileChain profileNames}

        chain builders {
          ct direction reply accept
          ${stub}
          ${local}
          ${shared}
          ${publicRule [
            80
            443
          ]}
          ${reject}
        }

        chain netctl_only {
          ct direction reply accept
          ${stub}
          ${local}
          ${shared}
          ${reject}
        }

        chain confined {
          ct direction reply accept
          ${lib.optionalString (cfg.slotLoopback == "reject") ''
            ${stub}
            ${local}
          ''}
          ${shared}
          ${lib.concatMapStrings (
            profile: "meta skuid @${slots.uidSet profile} jump profile_${slots.profileId profile}\n"
          ) profileNames}
          ${reject}
        }

        chain egress {
          type filter hook output priority filter; policy accept;
          meta skuid @slot_uids jump confined
          meta skgid ${toString config.ids.gids.nixbld} jump builders
          meta skuid @netctl_uids jump netctl_only
        }
      '';

      lanType = lib.types.submodule {
        options = {
          address = lib.mkOption {
            type = addressType;
            description = "An IPv4 or IPv6 address, or a CIDR range.";
          };
          ports = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            description = "The TCP ports of the host that the profile may reach.";
          };
        };
      };

      profileType = lib.types.submodule {
        options = {
          title = lib.mkOption {
            type = lib.types.str;
            description = "The name that a console shows for the profile.";
          };
          description = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "One line that says what the profile reaches.";
          };
          lan = lib.mkOption {
            type = lib.types.listOf lanType;
            default = [ ];
            description = ''
              LAN hosts and their ports. A profile never opens all ports of a
              LAN host, so an empty `ports` list is an error.
            '';
          };
          internet = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether the profile reaches public addresses.";
            };
            tcpPorts = lib.mkOption {
              type = lib.types.listOf lib.types.port;
              default = [
                80
                443
              ];
              description = "The TCP ports that the profile may reach on public addresses.";
            };
          };
        };
      };

      internalType = lib.types.submodule {
        options = {
          addresses = lib.mkOption {
            type = lib.types.listOf addressType;
            description = "Addresses or CIDR ranges of the host or hosts.";
          };
          tcpPorts = lib.mkOption {
            type = lib.types.listOf lib.types.port;
            default = [ ];
            description = ''
              The TCP ports that every profile may reach on these addresses.
              Required unless `allPorts` is set: a host that also runs a
              database must not be open to every slot.
            '';
          };
          allPorts = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Open every port of these addresses. Say so on purpose.";
          };
        };
      };
    in
    {
      options.permafrost.network = {
        profiles = lib.mkOption {
          type = lib.types.attrsOf profileType;
          default = { };
          description = ''
            The network profiles a slot can have, besides `internet-only`, which
            is always there. The name is what the netctl helper accepts: lower
            case letters, digits and `-`, 31 characters at most.
          '';
        };

        defaultProfile = lib.mkOption {
          type = lib.types.str;
          default = "internet-only";
          description = "The profile every slot has after a boot.";
        };

        internal = lib.mkOption {
          type = lib.types.attrsOf internalType;
          default = { };
          description = ''
            Hosts that every profile may reach (the caches, the Git host, the
            gateways), by address and port. The name is only for the reader of
            the declaration.
          '';
        };

        resolvers = lib.mkOption {
          type = lib.types.listOf addressType;
          default = lib.attrByPath [ "permafrost" "identity" "nameservers" ] [ ] config;
          defaultText = lib.literalExpression "config.permafrost.identity.nameservers";
          description = "The resolvers a slot may ask, on port 53.";
        };

        reservedRanges = {
          v4 = lib.mkOption {
            type = lib.types.listOf addressType;
            default = [
              "0.0.0.0/8"
              "10.0.0.0/8"
              "100.64.0.0/10"
              "127.0.0.0/8"
              "169.254.0.0/16"
              "172.16.0.0/12"
              "192.168.0.0/16"
              "224.0.0.0/3"
            ];
            description = "The IPv4 ranges that are not the internet: no profile reaches them by its internet rule.";
          };
          v6 = lib.mkOption {
            type = lib.types.listOf addressType;
            default = [
              "::/128"
              "::1/128"
              "fc00::/7"
              "fe80::/10"
              "ff00::/8"
            ];
            description = "The IPv6 ranges that are not the internet.";
          };
        };

        slotLoopback = lib.mkOption {
          type = lib.types.enum [
            "reject"
            "allow"
          ];
          default = "reject";
          description = ''
            `reject` stops a slot from connecting to any address of the guest,
            loopback included, so a slot cannot reach a listener of another
            slot. It also closes the dev servers of the slot itself. `allow`
            leaves loopback open, and with it the way between slots.
          '';
        };
      };

      config = {
        # Declared here, not as the option default: a default would vanish as
        # soon as a deployment declares its first profile of its own.
        permafrost.network.profiles.internet-only = {
          title = lib.mkDefault "Internet only";
          description = lib.mkDefault "Public addresses on ports 80 and 443, the internal list, and no LAN host.";
        };

        assertions = [
          {
            assertion = cfg.profiles ? ${cfg.defaultProfile};
            message = "permafrost.network.defaultProfile `${cfg.defaultProfile}` is not in permafrost.network.profiles.";
          }
          {
            assertion = lib.all (n: builtins.match "[a-z][a-z0-9-]{0,30}" n != null) profileNames;
            message = "A permafrost.network.profiles name is lower case letters, digits and `-`, starts with a letter, and has 31 characters at most.";
          }
          {
            assertion = lib.all (n: lib.all (e: e.ports != [ ]) (lanEntries n)) profileNames;
            message = "A permafrost.network.profiles lan entry needs at least one port. A profile never opens all ports of a LAN host.";
          }
          {
            assertion = lib.all (e: e.allPorts != (e.tcpPorts != [ ])) (lib.attrValues cfg.internal);
            message = "A permafrost.network.internal entry needs tcpPorts, or allPorts = true, and not both.";
          }
        ];

        networking.nftables = {
          enable = true;
          # The table is kept apart from the rules of the NixOS firewall, so the
          # ruleset is never flushed. A later `ruleset` must not flip this.
          flushRuleset = false;
          tables.permafrost = {
            family = "inet";
            content = table;
          };
        };
      };
    };
}
