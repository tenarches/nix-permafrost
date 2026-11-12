# Permafrost Technical Reference

This document serves as a densely packed technical reference for the underlying architecture, module definitions, and hypervisor constraints of Project Permafrost.

## The `cloud-hypervisor` Backend

We specifically target `cloud-hypervisor` (Rust-based) over QEMU to minimize the virtualization attack surface while retaining critical features like `virtiofs`.

### Networking
Unlike user-mode SLIRP networking (which `cloud-hypervisor` does not support), Permafrost uses `tap` interfaces. This is why `sudo` is required to launch the guest: the host must create and configure the `tap` device (`microvm-pf`, from `permafrost.identity.tapId = "pf"`) to route traffic to the external `wlp4s0` interface via the `microbr` bridge. The `microvm-` prefix is not cosmetic — the host's bridge network matches `matchConfig.Name = "microvm*"`, and a tap named anything else is created but never attached to `microbr`.

## The `modules/` Tree

There is no central registry file. `flake.nix` is `mkFlake { inherit inputs; }
(inputs.import-tree ./modules)` and nothing else — every `.nix` file under `modules/` is
discovered automatically and, unless its path contains a `/_` segment, treated as a
flake-parts module. Each module contributes to `flake.modules.<class>.<name>`, a namespace
declared once (`modules/flake/modules.nix`, importing `flake-parts.flakeModules.modules`)
that merges rather than collides — this is the [dendritic
pattern](https://github.com/mightyiam/dendritic).

```
modules/
├── flake/          perSystem infra: nixpkgs overlays, systems, dev shell, formatter, pre-commit
├── guest/          flake.modules.nixos.guest-*  — what the guest always is
│   └── home/       flake.modules.homeManager.agent-*  — the guest's one user's HM config
├── harness/        flake.modules.nixos.harness-*  — one file per agent CLI
├── host/           flake.modules.nixos.host-*  — the bridge, secrets, the fleet unit
├── packages/       perSystem packages.*  — permafrost, status, gc, ssh-config
├── _lib/           plain Nix, not modules — models.nix, shares.nix
└── _pkgs/          plain Nix, not modules — runner.nix, tools.nix, openclaude.nix, crosvm-graphics.nix
```

`import-tree` skips any path with a `/_` component, which is why `_lib` and `_pkgs` hold
importable functions and derivations rather than flake-parts modules — the naming is a
signal, not a filesystem trick.

### The `guest-*` / `harness-*` naming convention

A guest-wide concern (identity, shares, storage, the user, home-manager wiring) is
`flake.modules.nixos.guest-<name>`. An agent CLI is `flake.modules.nixos.harness-<name>`.
`modules/guest/module-list.nix` filters `config.flake.modules.nixos` for either prefix into
`flake.lib.guestModules`, the one list both launch paths import:

```nix
# modules/guest/module-list.nix
flake.lib.guestModules = lib.attrValues (
  lib.filterAttrs (
    name: _: lib.hasPrefix "guest-" name || lib.hasPrefix "harness-" name
  ) config.flake.modules.nixos
);
```

A standard harness definition looks like this — the whole of `modules/harness/opencode.nix`:

```nix
{ inputs, ... }:
{
  flake.modules.nixos.harness-opencode =
    { pkgs, ... }:
    {
      environment.systemPackages = [
        inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.opencode
      ];

      permafrost.shares = [
        { host = ".config/opencode"; guest = ".config/opencode"; }
      ];
    };
}
```

`permafrost.shares` (option declared in `modules/guest/shares.nix`) is what each harness
writes into rather than a central list being edited: `host` is a path relative to the
launching user's home, `guest` is where it lands under `/home/agent` (also the name under
`/mnt/persist` and the input to the virtiofs tag, so it must be unique), and an optional
`link` adds one more symlink for a harness that wants a single file rather than the whole
directory — `.claude.json`, linking into the `.claude-config` share, is the example in
`modules/harness/claude.nix`.

**Adding an agent is adding one file.** Nothing central needs editing: name the module
`harness-<name>`, and `module-list.nix` picks it up on its own — the failure mode of typoing
the prefix is silence (the module simply never reaches `guestModules`), not an evaluation
error, so double-check the prefix.

*Note: `openclaude` is vendored locally (`modules/_pkgs/openclaude.nix`) rather than pulled
from an external upstream flake, for hermetic reliability. That is a packaging detail only —
`harness/openclaude.nix` is a harness module like any other, declaring its own packages and
its own shares.*

## Guest accounts

The guest has two logins that run commands, and one more login for each factory slot. A last
login, `netctl`, runs one command and no shell. All are declared in `modules/guest/`.

| Account | uid / gid | Home | Reaches the host through | Login |
|---|---|---|---|---|
| `agent` | 1000 / `users` | `/home/agent`, the `home.img` volume | the shares under `/mnt/persist`, linked into its home | serial console, ssh with the launching user's keys, ssh with a CA certificate |
| `adurable` | 1001 / 1001 (`adurable`) | `/home/adurable`, the `adurable-home.img` volume | nothing | ssh with a CA certificate only |
| `f-slot1` to `f-slotN` | 2001 and up / the same number, group of the same name | `/home/slots/f-slotN`, on the `slots-home.img` volume | the workspaces share only, at `/home/slots/f-slotN/workspaces` (see [Workspaces share](#workspaces-share)) | ssh with a CA certificate only |
| `netctl` | 1002 / 1002 (`netctl`) | none (`/var/empty`) | nothing | ssh with a CA certificate only, one forced command |

`agent` is the account of the owner's harnesses (`modules/harness/*.nix`). Their sign-in
files are the virtiofs shares, and the launch credentials are in `/run/launch`. Anything
that reads untrusted text must not run as `agent`.

`adurable` (`modules/guest/adurable.nix`) is the account pi-durable runs its model tool
commands as:

- **No key, no password.** The password is locked (`!`). `AuthorizedKeysFile none` and
  `AllowAgentForwarding no` apply to it in a `Match User adurable` block, so the keys the
  runner harvests for `agent` and any `~/.ssh/authorized_keys` it writes do not log in. A
  certificate does, when one of its principals is `adurable`. That is sshd's default rule
  (no `AuthorizedPrincipalsFile`, see `modules/guest/ssh-ca.nix`), so a certificate for
  `agent` or `root` does not log in as `adurable`, and the reverse. The Vault SSH CA role
  that signs for it is `ssh-client-signer/sign/durable`.
- **No groups.** Its primary group is its own. It is not in `users`, `video`, `render`,
  `systemd-journal` or `wheel`.
- **No share.** There is no virtiofs share and nothing under `/mnt/persist` for it. Its home
  is a disk volume recreated on every boot, so what it writes goes when the VM stops. The
  home is mode 0700, and `tmpfiles` creates `work` and `workspaces` in it.
- **Closed to it:** `/home/agent` is 0700. `/mnt/persist` is 0700 and owned by `agent`
  (`modules/guest/shares.nix`), so a share cannot be reached by path whatever mode its host
  directory has. `/run/launch` is a virtiofs share whose host directory the runner makes
  0700, so only root reads it.
- **Nix.** `nix.settings.allowed-users` lists `agent` and `adurable`, so both can use the
  daemon. `trusted-users` stays `root`. `git`, `bash` and `nix` are on its `PATH` from the
  system packages.

### Slot accounts

`modules/guest/slots.nix` makes one account for each factory slot. pi-durable runs the
commands of one factory as one slot, so two factories that read untrusted text in the same
guest cannot read each other's files. The options are under `permafrost.slots`:

| Option | Default | Meaning |
|---|---|---|
| `count` | `16` (1 to 99) | The number of accounts, `<userPrefix>1` to `<userPrefix><count>`. |
| `userPrefix` | `f-slot` | The start of every account name. |
| `uidBase` | `2000` | Slot n has uid and gid `uidBase + n`. |
| `homeRoot` | `/home/slots` | The mount point of the one volume that holds every slot home. |
| `homeVolumeSizeMiB` | `131072` | The size of that volume. It is sparse, so this is a cap. |
| `workspaces.enable` | `true` | Mount the workspaces share and bind each slot's part into its home. The launch module supplies the share. |
| `workspaces.hostPath` | `/var/lib/permafrost-workspaces` | The host directory that the share carries. |
| `workspaces.hostIdBase` | `2000000000` (1879048192 to 2147483000) | The host ids of the slots start here (see [Workspaces share](#workspaces-share)). |

- **Login.** As for `adurable`: no key, no password (locked). `AuthorizedKeysFile none`,
  `AuthorizedPrincipalsFile none` and no forwarding of any kind (agent, TCP, stream-local,
  X11, tunnel, `~/.ssh/rc`) apply to each slot in its own `Match User` block. A certificate
  logs in as the slot when one of its principals is the account name, so a certificate for
  `f-slot1` does not log in as `f-slot2`, `adurable` or `root`. The `Match` blocks and the
  `adurable` block use `lib.mkAfter`: a global line that another module adds at the default
  order stays above every block.
- **No groups.** The primary group of a slot has the name of the slot, and nothing else is in
  it. A slot is in none of `users`, `video`, `render`, `systemd-journal` and `wheel`.
- **Home.** `/home/slots/f-slotN` is on `slots-home.img`, one volume for all slots, recreated
  on every boot. Each home is mode 0700, and `/home/slots` is 0711, so a slot can reach its
  own home and cannot list the others. `tmpfiles` creates `tmp` and `work` in it. Nothing a
  slot writes there reaches the host, except what it writes in `workspaces` (below).
- **TMPDIR.** `/tmp` is one shared volume. The `Match` block of each slot sets
  `TMPDIR=/home/slots/f-slotN/tmp`, so the commands of an ssh session do not put their files
  in `/tmp`. This is why the blocks are written one for each slot: `SetEnv` does not expand `%u`.
- **umask.** An ssh session of an account like `adurable` runs with umask 0022. For slot uids
  only, a `pam_umask` rule on the `sshd` and `login` services sets 0027, and a drop-in sets
  `UMask=0027` on `user@<uid>.service` of each slot, for the `systemd --user` units that do not
  pass through sshd. A file of a slot has mode 0640 and a directory 0750.
- **Tooling.** Each slot gets the Home Manager module `agent-environment` and nothing else
  (`devenv`, `uv`, `nodejs` and the Nix linters), as `adurable` does. This adds one
  `home-manager-f-slotN.service` for each slot at boot. The cost is not measured.
- **Nix.** `nix.settings.allowed-users` lists the slots. `trusted-users` stays `root`.
- **Workspaces.** `/home/slots/f-slotN/workspaces` is the part of the workspaces share that
  belongs to the slot, bind mounted into its home. This is the one place where what a slot
  writes reaches the host disk. See [Workspaces share](#workspaces-share).

Not done: a slot can list the processes of the other accounts (see below). `/tmp` is shared,
and only ssh sessions get the `TMPDIR` above. There is no CPU, memory or disk limit for a
slot, and a slot that fills `slots-home.img` starves the others. Unix sockets (abstract ones
too) and the Nix store are shared between all accounts. What a slot may reach over TCP and UDP
is the subject of the next section, and what a slot may leave on the host disk is the subject of
[Workspaces share](#workspaces-share): guest root can change files that exist there, and only
the read-only mount on the host stops the reader from writing.

### Network access

`modules/guest/network-egress.nix` puts one nftables table, `inet permafrost`, in the output hook
of the guest. The rules decide by the uid of the socket owner, by destination and by port. The
NixOS firewall table stays as it is (`networking.nftables.tables` is used, not `ruleset`, and
`flushRuleset` is `false`). Every slot starts in the default profile, and `netctl` moves a slot
to another one (see the next section). The profile of each slot is kept in `/run`, so it lasts
until a reboot, which puts every slot back in the default profile. A reload or restart of
`nftables.service` deletes and loads the table again; `permafrost-netctl-restore.service` then
applies the recorded profiles again (the slots have the default profile for a short time in between). The table fails closed: `permafrost-egress-guard.service` runs before sshd and fails
unless the chain `egress` is loaded and jumps to `confined`, so a ruleset that did not load leaves
the guest without a login, and the serial console is the way in.

The options are under `permafrost.network`:

| Option | Default | Meaning |
|---|---|---|
| `profiles.<name>` | `internet-only` only | The profiles a slot can have. `internet-only` is always there. A name has lower case letters, digits and `-`, 31 characters at most. |
| `profiles.<name>.title`, `.description` | | The name and the one line that a console shows. |
| `profiles.<name>.lan` | `[]` | LAN hosts and ports: a list of `{ address; ports; }`. An address is an IPv4 or IPv6 address or a CIDR range. An empty `ports` list is an error: a profile never opens all ports of a host. |
| `profiles.<name>.internet.enable`, `.tcpPorts` | `true`, `[ 80 443 ]` | Whether the profile reaches public addresses, and on which TCP ports. |
| `defaultProfile` | `internet-only` | The profile of every slot after a boot. |
| `internal.<name>` | `{}` | Hosts that every profile may reach, by address: `{ addresses; tcpPorts; allPorts; }`. `tcpPorts` is required unless `allPorts = true`, and the two do not go together. |
| `resolvers` | `permafrost.identity.nameservers` | The resolvers a slot may ask, on port 53. |
| `reservedRanges.v4`, `.v6` | loopback, private, CGNAT, link-local, multicast, unique-local; for IPv6 also the prefixes that carry an IPv4 address (`::ffff:0:0/96`, `64:ff9b::/96`, `64:ff9b:1::/48`, `2002::/16`, `2001::/32`) | The ranges that are not the internet. A NAT64 address such as `64:ff9b::c0a8:105` is the LAN host `192.168.1.5`, so it is not public. |
| `slotLoopback` | `reject` | `reject` stops a slot from connecting to any address of the guest. `allow` takes the rule out. |

The internal list is addresses, not names. nftables resolves a name when it loads the rules, and
a lookup that fails before the network is up fails the whole load. A deployment fills
`internal` with the addresses it knows (the Git host, the caches, the gateways).

The rules for a slot, in order:

1. Answers on connections that began from outside (`ct direction reply`), so a listener of a slot
   still works for a client.
2. The resolved stub, `127.0.0.53`, port 53, TCP and UDP.
3. Nothing on the guest itself (`fib daddr type local`): not loopback, not the guest address. This
   also closes slot to slot, because nftables cannot see who owns a listening socket. A slot
   cannot reach its own dev server on `localhost` either. `slotLoopback = "allow"` takes this
   rule out, and with it the way between slots.
4. The declared resolvers, port 53.
5. The internal list.
6. The profile of the slot: its LAN hosts and ports, then the internet (every address outside
   `reservedRanges`, on the ports of the profile).
7. Reject.

The rules have no `ct state established` shortcut, so a change of profile applies to the next
packet of a connection that is already open. A reject is an ICMP error (`icmpx
admin-prohibited`), and a TCP reset for TCP over IPv6, so a tool fails at once and does not wait
for a timeout. The errno is `EHOSTUNREACH` for IPv4 TCP, `ECONNREFUSED` for IPv6 TCP, and `EPERM`
or `ECONNREFUSED` for UDP. For IPv6 TCP the first ICMPv6 error does not reach the socket, and
the connect fails one second later with `EACCES` (seen in the VM check), so the reset is used
there.

Two more groups are confined, because both would be a way round the profile of a slot:

- **The Nix build users** (group `nixbld`). The fetch of a fixed-output derivation has network
  access, and a slot may start one. The rules cannot tell which slot asked for the build, so these
  get the declared resolvers, the internal list and the public ports that every declared profile
  allows: the narrowest profile sets the limit, and one profile with `internet.enable = false`
  takes the public ports away from all builds. They never reach a LAN host. A fetch from a LAN
  host inside `nix build` fails, also for a slot on a LAN profile. With the default profile
  alone, a build reaches public 80 and 443. The check `confinement-config` evaluates the table
  with a profile without internet and with a profile for port 443 only.
- **`netctl`**. The internal list and the resolvers only.

Everyone else is not filtered: `root`, the daemons, `agent` and `adurable` fall through the
accept policy of the chain. The chain `egress` holds three jumps and no other rule (the eval
check `egress-config` tests that), so a packet without a socket owner (an answer from a request
socket, a kernel reset) is never rejected.

Reserved ranges are not "the internet". TEST-NET (`192.0.2.0/24`, `198.51.100.0/24`,
`203.0.113.0/24`) and `2001:db8::/32` are not listed, so they count as public. The VM check uses
`203.0.113.0/24` as the internet for that reason. `100.64.0.0/10` is listed, because tailscale
and carrier NAT live there: a deployment that needs a tailnet host adds it to `internal` or to
a LAN profile.

Not done: the table does not see AF_VSOCK to the host, unix sockets (abstract ones too), `/tmp` or
the Nix store, which stay shared between all accounts. A name lookup leaves through the declared
resolver, so query names are a channel of low bandwidth. The way to close these is one network
namespace and one private `/tmp` for each slot job.

### netctl protocol

`modules/guest/netctl.nix` is the one way to change the profile of a slot while the guest runs.
The harness logs in over ssh as `netctl` with a CA certificate (principal `netctl`). The account
has `permafrost-netctl-ssh` as its login shell and as its `ForceCommand`, no home, no group, no
tty and no forwarding (`PermitOpen none`, `PermitListen none`, and every forwarding option off).
The wrapper checks the line it was given, and sends it to a socket, `/run/permafrost-netctl.sock`,
that is `root:netctl 0660`. A socket-activated helper reads the line, checks it again, and moves
the uid of the slot between the sets of the table.

The helper runs as a dynamic user with `CAP_NET_ADMIN` and no inet socket (`AF_UNIX` and
`AF_NETLINK` only), serves one connection after the other, and exits after ten idle seconds. There
is no sudo and no polkit. The Vault role that signs a `netctl` certificate is outside this
repository: only the harness may obtain one, and a slot has no way to widen its own profile
without it.

The grammar is one line of at most 64 characters from `a-z 0-9 -` and single spaces:

| Line | Answer |
|---|---|
| `list` | `ok list default=<profile> profiles=<p1>,<p2>,...` |
| `get <slot>` | `ok get slot=f-slot3 uid=2003 profile=<profile>` |
| `set <slot> <profile>` | `ok set slot=f-slot3 uid=2003 from=<old> to=<new> killed=<n>`, or `... profile=<p> unchanged` |
| `restore` | `ok restore slots=<n> killed=<k>`, `ok restore unchanged`, or `ok restore nothing`. Applies the recorded profiles again. `permafrost-netctl-restore.service` calls it after `nftables.service` loads. |

No verb takes a host, a port, an address or a uid. The slot and the profile are looked up in a table
that is written at build time, and the nft text is a fixed template with one number in it. A
failure is `err <code> <word>`, and the exit status of the ssh command is the code:

| Code | Word | Meaning |
|---|---|---|
| 0 | `ok` | Done. |
| 2 | `usage` | The line is outside the grammar. |
| 3 | `slot` | The slot is not declared. |
| 4 | `profile` | The profile is not declared. |
| 5 | `apply` | nft refused the change. |
| 6 | `internal` | The helper did not answer, or failed. |

Codes 2, 3 and 4 never change a rule. A change is one nft transaction (delete from the old set, add
to the new one: both or none). After a change the helper closes the established TCP connections of
that slot with `ss -K`, whatever the direction of the change, and reports `killed=<n>`. If the
kernel cannot do that, the answer ends with `kill=unsupported`, and the rules reject the next
packet of the connection. UDP and raw sockets are not closed.

Log lines go to the journal, tag `permafrost-netctl`: `netctl set slot=f-slot3 uid=2003
from=internet-only to=lan-test killed=2`, `netctl get slot=f-slot3`, `netctl reject code=3
reason=slot input=...` (the input is escaped and cut at 64 characters), and from the wrapper
`netctl-ssh peer=<address> accepted` or `rejected`.

Not done: `CAP_NET_ADMIN` lets a hijacked helper rewrite the whole ruleset, not only the uid
sets. The limit is the size of the helper and the mode of the socket.

Not done: `/proc` is not mounted with `hidepid`, so `adurable` and the slots can list the
processes of `agent` and of each other, with their command lines. NixOS removed its `security.hideProcessInformation` module because the mount option
breaks cgroups v2 session tracking, and systemd does not support it as a global setting.
It needs a boot test of the guest before it is added.

One local service is reachable by every account: the dsh web UI listens on
`127.0.0.1:3080` (`modules/harness/dsh.nix` sets the port), and any local user can connect.
Its browser login is a signed cookie. The one-time token that starts it is printed to the
journal of `dsh-web`, which `adurable` cannot read (it is not in `systemd-journal`). The
`/api` Host check accepts loopback, and that is a check on the Host header, not a login.
Whether a loopback request without the cookie is refused is not verified. The tailscale
daemon socket is also open to every account, with read-only status for any account that
is not root.

### Workspaces share

The workspaces of the slots live on the host disk, so a host service can read them (D-126 and
D-128 of pi-durable). One virtiofs share, tag `factory_ws`, carries the host directory
`/var/lib/permafrost-workspaces` (`permafrost.slots.workspaces.hostPath`) into the guest at
`/mnt/factory/workspaces`. The directory is not below `/var/lib/permafrost`, because
`nix run .#gc` deletes every directory there that has no running unit, and the runner removes
only `*.img` when the unit stops: nothing in the workspaces is removed by either. The
function `modules/_lib/slots.nix` holds the names, the ids and the flags, so the guest, the
runner, the fleet unit, the host module and the checks read one definition.

Layout, and the path rule that pi-durable uses:

| Where | Path |
|---|---|
| Host, written by the guest | `/var/lib/permafrost-workspaces/f-slotN/<repo>` |
| Host, read by the reader | `/srv/permafrost-workspaces/f-slotN/<repo>` (read-only view of the line above) |
| Guest, the slot | `/home/slots/f-slotN/workspaces/<repo>` |
| Guest, root only | `/mnt/factory/workspaces/f-slotN/<repo>` |

**Ids.** The slot `f-slotN` has uid and gid `2000 + N` in the guest and writes as host uid and
gid `2000000000 + N` (`permafrost.slots.workspaces.hostIdBase`). The range is above the
container ids of systemd (`0x70000000`) and below its foreign range (`0x7FFF0000`; the
option type keeps `hostIdBase + count` under it), so no account of a host has one of those
numbers, and no real host user owns a file of a slot. The map is made by virtiofsd
(`--translate-uid` and `--translate-gid`, no user namespace): five rules for the uid and the
same five for the gid, as written by `virtiofsdArgs`:

| Flag value | Meaning |
|---|---|
| `map:2001:2000000001:16` | Guest ids 2001 to 2016 are host ids 2000000001 to 2000000016, both ways. |
| `forbid-guest:0:2001` | A guest id from 0 to 2000 cannot create a file or take a file as owner. |
| `forbid-guest:2017:4294965278` | The same for every id above the slot range. |
| `squash-host:0:65534:2000000001` | Host ids 0 to 2000000000 (root, every real account, the reader group) show in the guest as 65534, nobody. |
| `squash-host:2000000017:65534:2294967278` | The same for every host id above the slot range. |

Only slots create files in the share. Guest root, `agent`, `adurable` and `netctl` cannot create
a file or `chown` one into a foreign id, so a file of the guest root never lands on the host.
`--posix-acl` cannot be used with the map, so the fleet share has `posixAcl = false` and there
are no ACLs or xattrs in the share. A host id outside the map shows in the guest as nobody, so a
host file owned by a real uid from 2001 to 2016 does not show as a slot's file. The audit unit
(below) still finds such a file. The check `workspaces-map-coverage` holds that the rules cover
every id once on both sides; `scripts/mapping-smoke.sh` runs them against a real virtiofsd.

**Modes.** `<hostPath>` is `root:2000000000 0750`. Each `<hostPath>/f-slotN` is
`2000000000+N:2000000000 2750` (setgid), so a file a slot makes gets the group `2000000000`,
and the umask of a slot (0027) makes it 0640 and a directory 0750. The group `2000000000` is
the reader group. No account of the guest has it.

**Who sees what in the guest.** `/mnt/factory` is `root 0700`, so a slot cannot reach the share
root or any other slot's directory. The slot sees only its own part, bind mounted at
`<home>/workspaces`, inside its 0700 home. A slot that opens its own directory with `chmod`
still hides it behind those two. The share and the bind mounts are `nosuid,nodev` and have no
`nosymfollow`: a symlink in a workspace works for the slot (`node_modules/.bin`, the `result`
link of `nix build`, worktrees). The unit `permafrost-factory-guard.service` runs before sshd
and fails unless `/mnt/factory` is `700 0 0`, so a failed `tmpfiles` run leaves the guest with
no login and not with an open share.

**Two launch paths, one set of flags.**

| Path | Host directory made by | virtiofsd |
|---|---|---|
| Runner (`nix run .#permafrost start`) | the runner, as root, before the guest starts: `install -d -m 2750 -o <hostUid> -g <readerGid>` for each slot, then `chmod 2750`. The shell function `safe_dir` runs before every `install` and stops the launch if the path is a symlink or not a directory. No `chown -R`, no `chmod -R`. | One more virtiofsd in the runner, `--sandbox namespace`, with the flags above. Socket `factory_ws.sock` in `/run/microvm-<name>/`. |
| Fleet (`microvm.vms.permafrost`) | `systemd.tmpfiles.rules` of `host/workspaces.nix` | The share of `launch-fleet.nix`: `posixAcl = false` and `extraArgs` with the flags. |

The checks `workspaces-flags`, `runner-guard` and `workspaces-ids-agree` pin this text. The
script `scripts/mapping-smoke.sh` runs the real flags against a throwaway virtiofsd and guest
(see below).

**The host module** `modules/host/workspaces.nix` (`flake.modules.nixos.host-workspaces`,
imported by `permafrost-host`) is for a host that holds the share. The options are under
`permafrost.host.workspaces`:

| Option | Default | Meaning |
|---|---|---|
| `path` | `/var/lib/permafrost-workspaces` | The directory of the share. |
| `readerPath` | `/srv/permafrost-workspaces` | Where the reader sees it. |
| `readerGroup` | `permafrost-ws` | The group of the reader. Its gid is `hostIdBase`. |
| `hostIdBase` | `2000000000` | As in the guest. |
| `count` | `16` | The number of slot directories. |
| `userPrefix` | `f-slot` | The start of the slot directory names. |

The defaults come from the same block in `_lib/slots.nix` as the guest options. When the host
evaluates the guest (`host-fleet`), `count`, `userPrefix`, `path` and `hostIdBase` are taken from
it with `mkDefault`. A host that starts the guest with the runner has no guest in its own
configuration, so the check `workspaces-ids-agree` compares the two sets of defaults.

- **Read-only view.** `fileSystems.<readerPath>` binds `path` with `bind,ro,nosymfollow,nosuid,nodev`.
  **This mount is the only write barrier.** A slot owns its tree and can `chmod -R g+w` it,
  which gives the reader group write bits; the read-only mount is what stops the write. So
  the group has one kind of member, the service that reads the workspaces, and that service
  reaches the data only through `readerPath` (`BindReadOnlyPaths` and `InaccessiblePaths = [ path ]`
  in its unit). The unit `permafrost-workspaces-ro-check.service` fails when `findmnt` shows no mount or does
  not show `ro`, `nosymfollow` and `nosuid`. It is not `RemainAfterExit`, so each start of a unit
  that has `Requires=` and `After=` on it runs the check again and a failed check stops that
  start. The unit of the reader MUST declare both (`After=` alone does not stop a start after a
  failure). A timer runs the check every minute, so a mount that was made writable later shows as a
  failed unit.
- **Audit.** `permafrost-workspaces-audit.service` runs daily (and can be started by hand),
  tag `permafrost-ws-audit`. It writes one warning for each file whose owner is outside
  `hostIdBase+1` to `hostIdBase+count`, or whose group is outside `hostIdBase` to
  `hostIdBase+count`, and a last line `found <n>`. It changes nothing. File names are passed through
  `tr`, so a name cannot start a log line.
- **Reader unit (not in this repository).** `services.nix-skills-mcp.readOnlyPaths = [ "/srv/permafrost-workspaces" ]`
  and `SupplementaryGroups = [ "permafrost-ws" ]` belong to the host configuration. git
  refuses a repository there with "dubious ownership", because the owner is a number that the
  service user does not have, and that is the right answer: **do not set `safe.directory`**. A slot
  writes `.git/config` and the hooks of its tree, and git runs `core.fsmonitor`, `core.sshCommand`,
  `core.pager` and `uploadpack.packObjectsHook` from there, as the reader, which holds the group
  read on every slot. The ownership check is the only thing in the way. A reader that must run git
  uses `-c core.fsmonitor= -c core.hooksPath=/dev/null`, `GIT_CONFIG_GLOBAL=/dev/null` and
  `GIT_CONFIG_NOSYSTEM=1`, which is a deny list of today's keys; a parser that reads the tree and
  does not run git is the better way.
- **Quota.** The share has no quota. On a host with ZFS the path should be its own dataset
  with `quota`.

Not done: guest root can still change, truncate, rename and `chmod` a file that exists in the
share, because virtiofsd acts with its own rights once the guest kernel has allowed the call.
Guest root already owns the data of every slot in the guest, so it is inside the trust
boundary for it. A setuid bit that guest root sets is inert for the reader (`nosuid`).
A slot can `chmod 700` its tree and hide it from the reader: the reader then fails and reads
nothing wrong. The reader mount does not follow symlinks, so `nix_verify` cannot follow a
symlink inside a repository. A credential in a workspace is readable by the reader, so no
credential belongs there. The virtiofsd of the share runs as root, with `--sandbox namespace`
as its own isolation: a bug in virtiofsd or in the id map is a host-facing surface. The shape
that virtiofsd runs unprivileged is not done. Setgid inheritance and the id map were not run
against the real guest (see `scripts/mapping-smoke.sh`).

#### The mapping smoke test

`scripts/mapping-smoke.sh` runs by hand and is not a flake check. It needs `sudo` (virtiofsd
runs as root, as it does for the guest) and `/dev/kvm`. It starts one virtiofsd on a `mktemp`
directory with the real flags (printed by `nix eval` from `_lib/slots.nix`), boots a minimal
initrd with qemu (no root file system, no disk, no network, none of the guest's state
directory), and makes files as guest uid 2001 and as guest root. Then it prints the owner,
group and mode of the host tree and `smoke ok` when they match: slot files `2000000001:2000000000`
with `640` and `2750`, no file made by root, `chown` to 0 or outside the slot range refused,
`chown` to another slot allowed. `SANDBOX=chroot` runs the same with another virtiofsd sandbox.
If `--translate-uid` and `--sandbox namespace` do not work together, the creates fail, and the
flag is the thing to change (record it in D-128).

### Autostart

`permafrost.host.autostart` (`modules/host/fleet.nix`, default `false`) sets
`microvm.vms.permafrost.autostart`, so the host wants `microvm@permafrost.service` at boot. It
exists only on a host with `host-fleet`.

The guest of that path has no `launch` share (no tailnet key, no dsh secret) and no `ssh_keys`
share, because only the runner can fill them (see `launch-fleet.nix`). Starting the guest
through `host-fleet` therefore changes what the guest can do. A host that starts the guest with
the runner (`sudo nix run .#permafrost start`) has no use for the option. It needs a boot unit
that starts the runner instead, and the runner needs `SUDO_USER` for the agent socket and for
minting the keys. The check `autostart-option` evaluates the host with the option off and on.

## Secret Injection Architecture — as designed, not as built

Handling secrets securely in declarative VMs is notoriously difficult. Permafrost's design
avoids baking secrets into the Nix store, but as built today only the host half of that
design is wired up:

1. **Host-Side Decryption (real).** The host unseals secrets (e.g., `anthropic-api-key`,
   `google-api-key`, via `sops-nix` and a TPM-sealed age key) to `/run/secrets/*`. This is
   declared in `modules/host/secrets.nix` and does run.
2. **The `extraArgsScript` route (present, but inert).** `cloud-hypervisor` lacks native
   parsing for `microvm.credentialFiles`. `modules/guest/base.nix`'s `extraArgsScript` reads
   the host secrets named there and dynamically constructs the `--platform
   oem_string=[...]` argument cloud-hypervisor accepts instead. It is gated on
   `mcfg.credentialFiles != { }` — and nothing in this tree ever sets
   `microvm.credentialFiles`, so the gate never opens and this code never runs.
3. **Guest Consumption (never reached).** In principle the guest kernel would read the OEM
   strings and `systemd` would mount them to `/run/host/credentials/` for the agent process
   to consume. Since step 2 never fires, no credential reaches the guest by this route
   today. A harness that needs a credential gets it some other way — `dsh`'s endpoint takes
   no key at all, for instance.

The machinery is kept rather than removed because it is the only credential route
cloud-hypervisor currently offers and rediscovering it would be expensive — but treat it as
a documented gap, not a working pipeline, until something actually populates
`microvm.credentialFiles`.
