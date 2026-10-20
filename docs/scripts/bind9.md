# BIND9 LXC

Installs Debian 13's `bind9`, `bind9-utils`, `bind9-dnsutils` and `socat` through the community-scripts CT framework. Default resources: 1 CPU, 1 GiB RAM, 8 GiB disk, unprivileged CT.

The service is masked before package installation, then started with DNS restricted to loopback. Edit `/etc/bind/named.conf.options` and `/etc/bind/named.conf.local` before serving clients. Set private client ACLs for queries and recursion, and use TSIG-authenticated transfers for replicas. Keep writable zones and DNSSEC keys under `/var/lib/bind` with appropriate `bind` ownership.

Validate with `named-checkconf -z`, reload with `rndc reconfig`, and inspect `journalctl -u named`. The update function synchronizes journals, saves configuration and zone data in a mode-0700 directory under `/opt`, validates configuration, and upgrades the Debian packages.

Optional integration is configured separately:

- Stork Agent can monitor BIND through loopback-only statistics and RNDC endpoints.
- BIND emits dnstap through a local Unix socket; a relay can securely forward this stream to a separate collector.
- When migrating Kea D2, its `ddns-domains` entries must name actual authoritative SOA zones, not arbitrary suffixes accepted by a previous DNS server. Preserve DHCID ownership records and test RFC2136 prerequisites.
- Preserve original DNSSEC private keys and their activation dates when importing a signed zone. Use a controlled initial re-sign and verify using the original trust anchor before switching clients.

This installer does not enable DHCP or automatically migrate any DNS server. No private LAN addresses, credentials or deployment-specific policy are included.
