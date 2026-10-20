#!/usr/bin/env bash
# Copyright (c) 2026 community-scripts ORG
# Author: ryanbuu
# License: MIT | https://github.com/ryanbuu/ProxmoxVED/raw/main/LICENSE
# Source: https://www.isc.org/bind/
# shellcheck disable=SC1091
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os
msg_info "Installing BIND"
systemctl mask named.service
$STD apt install -y bind9 bind9-utils bind9-dnsutils socat python3
msg_ok "Installed BIND"
msg_info "Configuring Loopback-only DNS"
cat <<'CONF' >/etc/bind/named.conf.options
options {
  directory "/var/cache/bind";
  listen-on { 127.0.0.1; };
  listen-on-v6 { ::1; };
  allow-query { localhost; };
  allow-recursion { localhost; };
  allow-transfer { none; };
  dnssec-validation auto;
};
CONF
$STD named-checkconf -z
systemctl unmask named.service
systemctl enable -q --now named.service
msg_ok "Configured Loopback-only DNS"
motd_ssh
customize
cleanup_lxc
