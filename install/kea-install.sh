#!/usr/bin/env bash

# Copyright (c) 2026 community-scripts ORG
# Author: ryanbuu
# License: MIT | https://github.com/ryanbuu/ProxmoxVED/raw/main/LICENSE
# Source: https://www.isc.org/kea/

# shellcheck disable=SC1091
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# This installer uses Debian's package names, service units and configuration paths.
# shellcheck disable=SC1091
source /etc/os-release
if [[ "$ID" != "debian" || "$VERSION_ID" != "13" ]]; then
  msg_error "Kea requires Debian 13 for this installation method"
  exit 1
fi

msg_info "Preventing Automatic DHCP Startup"
# Mask BEFORE apt: maintainer scripts must not start a second DHCP server.
systemctl mask kea-dhcp4-server.service kea-dhcp-ddns-server.service kea-ctrl-agent.service
msg_ok "Prevented Automatic DHCP Startup"

msg_info "Installing Kea"
$STD apt install -y kea-dhcp4-server kea-dhcp-ddns-server kea-ctrl-agent
msg_ok "Installed Kea"

msg_info "Configuring Kea"
# Services are masked, so systemd has not created their RuntimeDirectory yet.
# Kea 2.6.3+ checks this directory even during Control Agent's -t validation.
cat <<'TMPFILES' >/etc/tmpfiles.d/kea-helper.conf
d /run/kea 0750 _kea _kea -
TMPFILES
systemd-tmpfiles --create /etc/tmpfiles.d/kea-helper.conf
# No subnet or pool is enabled. Configure these before unmasking the services.
cat <<'CONF' >/etc/kea/kea-dhcp4.conf
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": ["eth0"],
      "dhcp-socket-type": "udp"
    },
    "control-socket": {
      "socket-type": "unix",
      "socket-name": "/run/kea/kea4-ctrl-socket"
    },
    "lease-database": {
      "type": "memfile",
      "persist": true,
      "name": "/var/lib/kea/kea-leases4.csv",
      "lfc-interval": 3600
    },
    "valid-lifetime": 86400,
    "renew-timer": 21600,
    "rebind-timer": 43200,
    "dhcp-ddns": {
      "enable-updates": false,
      "server-ip": "127.0.0.1",
      "server-port": 53001
    },
    "subnet4": [],
    "loggers": [{
      "name": "kea-dhcp4",
      "output_options": [{"output": "stdout"}],
      "severity": "INFO"
    }]
  }
}
CONF
cat <<'CONF' >/etc/kea/kea-dhcp-ddns.conf
{
  "DhcpDdns": {
    "ip-address": "127.0.0.1",
    "port": 53001,
    "tsig-keys": [],
    "forward-ddns": {"ddns-domains": []},
    "reverse-ddns": {"ddns-domains": []},
    "loggers": [{
      "name": "kea-dhcp-ddns",
      "output_options": [{"output": "stdout"}],
      "severity": "INFO"
    }]
  }
}
CONF
cat <<'CONF' >/etc/kea/kea-ctrl-agent.conf
{
  "Control-agent": {
    "http-host": "127.0.0.1",
    "http-port": 8000,
    "control-sockets": {
      "dhcp4": {
        "socket-type": "unix",
        "socket-name": "/run/kea/kea4-ctrl-socket"
      }
    },
    "loggers": [{
      "name": "kea-ctrl-agent",
      "output_options": [{"output": "stdout"}],
      "severity": "INFO"
    }]
  }
}
CONF
# Debian ships root-owned conffiles; grant the service account read access.
chown root:_kea /etc/kea/kea-dhcp4.conf /etc/kea/kea-dhcp-ddns.conf /etc/kea/kea-ctrl-agent.conf
chmod 640 /etc/kea/kea-dhcp4.conf /etc/kea/kea-dhcp-ddns.conf /etc/kea/kea-ctrl-agent.conf
$STD runuser -u _kea -- kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
$STD runuser -u _kea -- kea-dhcp-ddns -t /etc/kea/kea-dhcp-ddns.conf
$STD runuser -u _kea -- kea-ctrl-agent -t /etc/kea/kea-ctrl-agent.conf
msg_ok "Configured Kea (Services Remain Masked)"

cat <<'GUIDE' >/etc/kea/README.helper-scripts
Kea DHCP helper-script installation
===================================
Debian packages: kea-dhcp4-server, kea-dhcp-ddns-server, kea-ctrl-agent.
Services are MASKED and no address pool is configured.

1. Assign a static CT address using Proxmox network settings.
2. Configure /etc/kea/kea-dhcp4.conf with your subnets, pools, router,
   DNS servers, reservations and relay addresses. UDP sockets are configured
   for relayed DHCP; directly attached broadcast clients need raw sockets.
3. If using HA, configure TWO nodes before enabling either one. Discover
   packaged hook paths with:
     dpkg -L kea-common | grep -E 'libdhcp_(ha|lease_cmds)\.so$'
   Enable the lease_cmds and ha hooks, configure hot-standby peers, and
   protect their Control Agent endpoints with authentication and firewall rules.
   Both nodes need matching subnet/pool/reservation configuration; lease
   synchronization does not synchronize the configuration files.
4. If using Technitium DDNS, configure D2 with forward/reverse zones and a
   TSIG key, and enable DHCP-DDNS updates in kea-dhcp4.conf. Allow A/PTR/DHCID
   updates for the dedicated key in the corresponding Technitium zones.
5. Validate configurations:
     kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
     kea-dhcp-ddns -t /etc/kea/kea-dhcp-ddns.conf
     kea-ctrl-agent -t /etc/kea/kea-ctrl-agent.conf
   These checks do not exercise live sockets, HA negotiation, or DNS updates.
6. Transfer existing leases/reservations or exclude all unexpired old leases
   from the new pool. Disable the old DHCP server before switching the relay.
7. Unmask and enable ONLY the services you configured:
     systemctl unmask kea-dhcp4-server
     systemctl enable --now kea-dhcp4-server
   For HA also unmask/enable kea-ctrl-agent; for DDNS do the same for
   kea-dhcp-ddns-server (start D2 before DHCP).
8. Verify DHCP DORA, renewal, A/PTR updates, failover and recovery using a
   test client. Review journalctl -u kea-dhcp4-server.

Stork is an optional, separate management platform; it is not bundled here.
Documentation: https://kea.readthedocs.io/en/kea-2.6.3/
HA guide: https://kb.isc.org/docs/kea-ha-quickstart-guide
Fork guide: docs/scripts/kea.md in ryanbuu/ProxmoxVED
GUIDE

motd_ssh
customize
# customize() writes an upstream-only update URL. Keep this CT on the fork.
cat <<EOF_UPDATE >/usr/bin/update
#!/usr/bin/env bash
export COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/ryanbuu/ProxmoxVED/main}"
bash -c "\$(curl -fsSL "\$COMMUNITY_SCRIPTS_URL/ct/kea.sh")"
EOF_UPDATE
chmod +x /usr/bin/update
cleanup_lxc
