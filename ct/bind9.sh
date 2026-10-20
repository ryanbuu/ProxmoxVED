#!/usr/bin/env bash
# shellcheck disable=SC1090
export COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/ryanbuu/ProxmoxVED/feat/bind-ct}"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func")
# Copyright (c) 2026 community-scripts ORG
# Author: ryanbuu
# License: MIT | https://github.com/ryanbuu/ProxmoxVED/raw/main/LICENSE
# Source: https://www.isc.org/bind/
APP="BIND9"
var_tags="${var_tags:-network;dns}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-8}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_arm64="${var_arm64:-yes}"
var_unprivileged="${var_unprivileged:-1}"
header_info "$APP"
variables
color
catch_errors
function update_script() {
  header_info
  check_container_storage
  check_container_resources
  command -v named >/dev/null || {
    msg_error "No BIND Installation Found!"
    exit 1
  }
  $STD named-checkconf -z
  msg_info "Backing up BIND Configuration and Zones"
  local backup_dir
  backup_dir="$(mktemp -d /opt/bind9-backup.XXXXXX)"
  chmod 700 "$backup_dir"
  $STD rndc sync
  cp -a /etc/bind /var/lib/bind "$backup_dir/"
  msg_ok "Backed up BIND to ${backup_dir}"
  msg_info "Updating BIND"
  $STD apt update
  $STD apt install -y --only-upgrade bind9 bind9-utils bind9-dnsutils
  $STD named-checkconf -z
  systemctl try-restart named
  msg_ok "Updated BIND"
  exit
}
start
build_container
description
msg_ok "Completed successfully!"
echo -e "${INFO}${YW}BIND listens on loopback only until you configure zones and access controls.${CL}"
echo -e "${TAB}${BGN}Configuration: /etc/bind/ | Zones: /var/lib/bind/${CL}"
