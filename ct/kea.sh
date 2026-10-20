#!/usr/bin/env bash
# shellcheck disable=SC1090
export COMMUNITY_SCRIPTS_URL="${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/ryanbuu/ProxmoxVED/main}"
source <(curl -fsSL "$COMMUNITY_SCRIPTS_URL/misc/build.func")
# Copyright (c) 2026 community-scripts ORG
# Author: ryanbuu
# License: MIT | https://github.com/ryanbuu/ProxmoxVED/raw/main/LICENSE
# Source: https://www.isc.org/kea/

APP="Kea"
var_tags="${var_tags:-network;dhcp}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-512}"
var_disk="${var_disk:-4}"
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
  if [[ ! -f /etc/kea/kea-dhcp4.conf ]] || ! command -v kea-dhcp4 &>/dev/null; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi

  msg_info "Validating Kea Configuration"
  $STD kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
  $STD kea-dhcp-ddns -t /etc/kea/kea-dhcp-ddns.conf
  $STD kea-ctrl-agent -t /etc/kea/kea-ctrl-agent.conf
  msg_ok "Validated Kea Configuration"

  msg_info "Backing up Kea Configuration"
  local backup_dir
  backup_dir="$(mktemp -d /opt/kea-config-backup.XXXXXX)"
  chmod 700 "$backup_dir"
  cp -a /etc/kea/. "$backup_dir/"
  msg_ok "Backed up Kea Configuration to ${backup_dir}"

  # Package upgrades must not activate a staged/disabled DHCP server.
  local service result=0
  local -a active_services=() temporary_masks=()
  for service in kea-dhcp4-server kea-dhcp-ddns-server kea-ctrl-agent; do
    if systemctl is-active --quiet "$service"; then
      active_services+=("$service")
    fi
    case "$(systemctl is-enabled "$service" 2>/dev/null || true)" in
      masked | masked-runtime) ;;
      *)
        systemctl mask --runtime "$service"
        temporary_masks+=("$service")
        ;;
    esac
  done

  msg_info "Updating Kea Packages"
  if $STD apt update && $STD apt install -y --only-upgrade \
    kea-common kea-dhcp4-server kea-dhcp-ddns-server kea-ctrl-agent; then
    msg_ok "Updated Kea Packages"
  else
    result=1
  fi
  for service in "${temporary_masks[@]}"; do
    systemctl unmask --runtime "$service"
  done
  if ((result)); then
    msg_error "Package update failed. Configuration backup: ${backup_dir}"
    exit 1
  fi

  msg_info "Validating Updated Kea Configuration"
  $STD kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
  $STD kea-dhcp-ddns -t /etc/kea/kea-dhcp-ddns.conf
  $STD kea-ctrl-agent -t /etc/kea/kea-ctrl-agent.conf
  msg_ok "Validated Updated Kea Configuration"

  for service in "${active_services[@]}"; do
    systemctl restart "$service"
  done
  msg_ok "Updated successfully; previously stopped services remain stopped"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${INFO}${YW}Kea is installed with DHCP, D2 and Control Agent masked.${CL}"
echo -e "${TAB}${BGN}Configuration: /etc/kea/ | Instructions: /etc/kea/README.helper-scripts${CL}"
echo -e "${TAB}${BGN}Set a static CT address before enabling DHCP or configuring HA.${CL}"
echo -e "${TAB}${BGN}Kea has no built-in web UI; Stork is installed separately.${CL}"
