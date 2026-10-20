# Kea DHCP CT

Creates an unprivileged Debian 13 CT using the existing helper-script wizard.
Defaults: 1 vCPU, 512 MiB RAM, 4 GiB disk. Installs Debian's `kea-dhcp4-server`,
`kea-dhcp-ddns-server` (D2) and `kea-ctrl-agent`; the `kea-common` dependency
includes the HA and lease-command hooks. This uses Debian's packaged release
(2.6.x at implementation time), not an upstream "latest" download. No Docker,
external package repository, Stork, or database server is installed.

## Install from this fork

Run on a Proxmox VE host after the files are available on the selected branch:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ryanbuu/ProxmoxVED/main/ct/kea.sh)"
```

For a feature branch, use its base URL for **both** the entry point and helpers:

```bash
export COMMUNITY_SCRIPTS_URL=https://raw.githubusercontent.com/ryanbuu/ProxmoxVED/feat/kea-ct
bash -c "$(curl -fsSL "$COMMUNITY_SCRIPTS_URL/ct/kea.sh")"
```

The generated `/usr/bin/update` retains this base URL. When the branch is
merged/deleted, change the URL in that file to the permanent branch.
Choose Advanced Settings to assign a static address and the correct bridge/VLAN.
A DHCP server must not depend on itself for its CT management address.

The installer masks all three services **before** installing packages, writes
empty DHCP/D2 configurations, validates them and leaves the services masked.
It does not alter a router, another DHCP server, or Technitium. There is no web
interface; Control Agent is an API listening on loopback when explicitly enabled.

## Configure a relayed DHCP server

Configuration is under `/etc/kea/`. In `kea-dhcp4.conf`, replace `subnet4: []`
with your network configuration, for example:

```json
"subnet4": [{
  "id": 1,
  "subnet": "198.51.100.0/24",
  "pools": [{"pool": "198.51.100.100 - 198.51.100.199"}],
  "relay": {"ip-addresses": ["198.51.100.1"]},
  "option-data": [
    {"name": "routers", "data": "198.51.100.1"},
    {"name": "domain-name-servers", "data": "192.0.2.53, 192.0.2.54"},
    {"name": "domain-name", "data": "lan.example"}
  ]
}]
```

These are documentation addresses. Replace every example address/domain before
using it. `relay.ip-addresses` identifies the relay's client-network address
(`giaddr`), not the Kea CT address. The UDP socket default is for relayed DHCP.
Directly attached broadcast clients require `dhcp-socket-type: raw`; retain the
normal LXC network capabilities and test on the intended bridge. Configure UDP
67 access between the gateway relay and CT. The relay forwards requests to the
CT's static address.

Before cutover, migrate reservations and leases, or exclude **all unexpired old
leases** from the new pool. Stopping the old server alone does not make its leased
addresses safe to reuse. Do not configure both old and new independent servers
with overlapping pools during migration.

After configuring and validating, disable the old DHCP service, switch the relay
and start only the required services:

```bash
kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
systemctl unmask kea-dhcp4-server
systemctl enable --now kea-dhcp4-server
journalctl -u kea-dhcp4-server -n 50 --no-pager
```

## Optional hot-standby HA

Create a second CT on a different PVE host. Use the examples in `misc/kea/`:

- `kea-dhcp4-ha.json` -> `/etc/kea/kea-dhcp4.conf`
- `kea-ctrl-agent-ha.json` -> `/etc/kea/kea-ctrl-agent.conf`
- `kea-dhcp-ddns-tsig.json` -> `/etc/kea/kea-dhcp-ddns.conf` (if using DDNS)

The examples are templates, not an installer option that configures a working
pair automatically. They use two CTs at `192.0.2.10` and `192.0.2.11`. On node 2,
change `this-server-name` to `kea2` and Control Agent `http-host` to `192.0.2.11`.
Keep both nodes' subnet IDs, pools, reservations, peer definitions and options
identical. Kea synchronizes leases, **not configuration files**.

Find the native hook directory on each CT:

```bash
dpkg -L kea-common | grep -E 'libdhcp_(lease_cmds|ha)\.so$'
```

Replace `@HOOK_DIR@` in the DHCP example with that directory. Load `lease_cmds`
before `ha`. Generate one shared HA password, replace every
`REPLACE_WITH_SHARED_RANDOM_PASSWORD` in both DHCP configs and both Control Agent
configs. Basic authentication requires a trusted, isolated management path; it
does not encrypt HTTP. The example uses TCP 8001 for the HA hook's dedicated listener and TCP 8000
for Control Agent. Restrict both ports to the partner CT (and explicitly
approved management sources), or configure TLS using the Kea documentation.
Do not expose Control Agent to client VLANs or the Internet.

The sample uses `max-unacked-clients: 1`, which requires more than one delayed
client after communication is lost. It avoids declaring partner-down merely
because a heartbeat connection failed, but a small/quiet LAN may not switch
quickly. Choose thresholds for your network and test with actual clients. Setting
it to zero changes split-brain behavior; do not tune blindly for fast failover.

Ensure the static CT address exists before starting Kea or its HTTP listeners.
A `network-online.target` dependency alone is insufficient unless the relevant
network manager's wait-online service is enabled; validate an actual CT reboot.

Configure the gateway to relay each client network to **both CT addresses**.
Allow peer heartbeat/lease traffic and DHCP relay traffic. Validate both configs,
then unmask/enable `kea-ctrl-agent` on each CT before starting DHCP. Test partner
down and recovery, and verify leases converge. Do not place both CTs on one host.

## Technitium A/PTR updates

D2 is Kea's separate RFC 2136 client. Configure forward and reverse domains in
`kea-dhcp-ddns.conf`, pointing at the **writable authoritative server** for each
zone. The TSIG example uses `lan.example.` and `100.51.198.in-addr.arpa.`.
Use your existing authoritative zone boundaries: a hostname suffix can be a
subdomain of a broader primary zone; it need not be made into a new zone.

Generate a dedicated TSIG secret (`openssl rand -base64 32`) and configure the
same key name/algorithm/secret in Technitium and D2. Do not reuse UniFi credentials.
Enable zone Dynamic Updates and constrain its policy to this key, required names,
and A/PTR/DHCID record types. Restrict update sources to the D2 CTs. Keep config
files readable only by root and the packaged service group (`chmod 640`).

The DHCP HA example enables both forward/reverse server updates and refreshes
updates on renewal. If you are not using D2, set `dhcp-ddns.enable-updates` and
`ddns-send-updates` to false. For DDNS, configure D2 on **both nodes**, validate,
and enable it before DHCP:

```bash
kea-dhcp-ddns -t /etc/kea/kea-dhcp-ddns.conf
systemctl unmask kea-dhcp-ddns-server
systemctl enable --now kea-dhcp-ddns-server
```

Existing A/PTR records from another DHCP server may fail Kea's DHCID ownership
checks. Reconcile those records during migration; do not globally disable conflict
checks to overwrite manually managed records.

DHCP HA does **not** make a Technitium secondary zone writable. If the DNS primary
is on the failed PVE host, DHCP can continue while new DDNS writes fail. Existing
replicated records can still resolve. Plan authoritative write recovery separately,
monitor D2 errors, and verify/reconcile missed updates after recovery. Neither a
DDNS queue nor lease replication guarantees permanent replay of every missed DNS
update.

## Updates and validation

Run `update` inside the CT. The updater validates existing configs, saves a
root-only backup under `/opt/kea-config-backup.*`, upgrades only Kea packages,
validates again and restarts only services that were running beforehand. Runtime
masks prevent APT from starting staged services; permanent masks are retained.
It does not rewrite user configuration, create HA peers, or back up live leases.
Perform HA node upgrades one at a time and verify recovery before the next node.

`-t` validates configuration but does not open production sockets, exercise HA
negotiation, or test authenticated DNS updates. Acceptance tests must cover:

1. DISCOVER/OFFER/REQUEST/ACK through the actual relay, and renewal.
2. Correct router/DNS/options and preservation of reservations.
3. A/PTR creation, lease changes and eventual cleanup.
4. Primary CT/PVE outage, standby allocation, and primary recovery.
5. DNS-primary outage and reconciliation of DDNS updates after recovery.

Stork can be added separately; its management features depend on the Kea version
and installed hooks. This installer does not claim to provision a Stork platform.

References: [Debian package](https://packages.debian.org/trixie/kea-dhcp4-server),
[ISC HA quickstart](https://kb.isc.org/docs/kea-ha-quickstart-guide),
[Kea 2.6.3 manual](https://kea.readthedocs.io/en/kea-2.6.3/),
[Technitium](https://github.com/TechnitiumSoftware/DnsServer).
