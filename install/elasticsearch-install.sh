#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: ryanbuu
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://www.elastic.co/elasticsearch

# shellcheck disable=SC1091
source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y apt-transport-https
msg_ok "Installed Dependencies"

setup_deb822_repo "elasticsearch" \
  "https://artifacts.elastic.co/GPG-KEY-elasticsearch" \
  "https://artifacts.elastic.co/packages/9.x/apt" \
  "stable" \
  "main"

msg_info "Installing Elasticsearch"
$STD apt install -y elasticsearch
msg_ok "Installed Elasticsearch"

msg_info "Configuring Elasticsearch"
ES_CONFIG="/etc/elasticsearch/elasticsearch.yml"
# Drop the security auto-configuration block written by the package on install
sed -i '/# BEGIN SECURITY AUTO CONFIGURATION/,/# END SECURITY AUTO CONFIGURATION/d' "$ES_CONFIG"
sed -i '/^xpack\.security\./d;/^cluster\.initial_master_nodes:/d' "$ES_CONFIG"
ES_DATA_PATH="${ES_DATA_PATH:-/var/lib/elasticsearch}"
cat <<EOF >>"$ES_CONFIG"

# Managed by community-scripts
network.host: 0.0.0.0
http.port: 9200
discovery.type: single-node
xpack.security.enabled: false
path.data: ${ES_DATA_PATH}
EOF
msg_ok "Configured Elasticsearch"

# Data directory may live on an attached (e.g. NFS) mountpoint; ensure it exists
# and is owned by the elasticsearch service user so the node can write to it.
msg_info "Preparing Data Directory"
mkdir -p "${ES_DATA_PATH}"
chown -R elasticsearch:elasticsearch "${ES_DATA_PATH}"
chmod 2750 "${ES_DATA_PATH}"
msg_ok "Prepared Data Directory (${ES_DATA_PATH})"

msg_info "Starting Elasticsearch"
systemctl enable -q --now elasticsearch
msg_ok "Started Elasticsearch"

msg_info "Checking Elasticsearch"
for i in {1..30}; do
  if curl -sf "http://127.0.0.1:9200" >/dev/null; then
    break
  fi
  sleep 2
done
curl -sf "http://127.0.0.1:9200" >/dev/null
msg_ok "Elasticsearch Running"

motd_ssh
customize
cleanup_lxc
