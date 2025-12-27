#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2025 Community-Script ORG
# Author: tteck (tteckster) | Co-Author: CrazyWolf13
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://nginxproxymanager.com/

APP="Nginx Proxy Manager"
var_tags="${var_tags:-proxy}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-8}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-22.04}"  # 20.04, 22.04, or 24.04
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  
  if [[ ! -f /lib/systemd/system/npm.service ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  # Ubuntu-specific optimization: Check for systemd-resolved and configure appropriately
  if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    msg_info "Configuring for systemd-resolved (Ubuntu)"
    # Use systemd-resolved stub resolver
    mkdir -p /etc/nginx/conf.d/include
    echo "resolver 127.0.0.53;" > /etc/nginx/conf.d/include/resolvers.conf
  else
    # Fallback to traditional resolv.conf
    echo resolver "$(awk 'BEGIN{ORS=" "} $1=="nameserver" {print ($2 ~ ":")? "["$2"]": $2}' /etc/resolv.conf);" >/etc/nginx/conf.d/include/resolvers.conf
  fi

  if command -v node &>/dev/null; then
    CURRENT_NODE_VERSION=$(node --version | cut -d'v' -f2 | cut -d'.' -f1)
    if [[ "$CURRENT_NODE_VERSION" != "22" ]]; then
      msg_info "Upgrading Node.js to version 22"
      systemctl stop openresty
      
      # Ubuntu-specific: Use Nodesource repository for Node.js 22
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
      apt-get purge -y nodejs npm
      apt-get autoremove -y
      apt-get install -y nodejs
      
      rm -rf /usr/local/bin/node /usr/local/bin/npm
      rm -rf /usr/local/lib/node_modules
      rm -rf ~/.npm
      rm -rf /root/.npm
    fi
  else
    # Fresh Node.js installation using Nodesource
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
    apt-get install -y nodejs
  fi

  # Install Yarn using Ubuntu's preferred method
  if ! command -v yarn &>/dev/null; then
    npm install -g yarn
  fi

  RELEASE="2.13.4"
  CLEAN_INSTALL=1 fetch_and_deploy_gh_release "nginxproxymanager" "NginxProxyManager/nginx-proxy-manager" "tarball" "v${RELEASE}" "/opt/nginxproxymanager"
  
  msg_info "Stopping Services"
  systemctl stop openresty
  systemctl stop npm
  msg_ok "Stopped Services"

  msg_info "Cleaning old files"
  $STD rm -rf /app \
    /var/www/html \
    /etc/nginx \
    /var/log/nginx \
    /var/lib/nginx \
    /var/cache/nginx
  msg_ok "Cleaned old files"

  msg_info "Setting up Environment"
  # Ubuntu-specific: Ensure python3 is properly linked
  if [[ ! -f /usr/bin/python ]]; then
    ln -sf /usr/bin/python3 /usr/bin/python
  fi
  
  # Install Ubuntu build dependencies
  apt-get install -y build-essential python3-dev python3-pip python3-venv
  
  ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx
  ln -sf /usr/local/openresty/nginx/ /etc/nginx
  sed -i "s|\"version\": \"2.0.0\"|\"version\": \"$RELEASE\"|" /opt/nginxproxymanager/backend/package.json
  sed -i "s|\"version\": \"2.0.0\"|\"version\": \"$RELEASE\"|" /opt/nginxproxymanager/frontend/package.json
  sed -i 's+^daemon+#daemon+g' /opt/nginxproxymanager/docker/rootfs/etc/nginx/nginx.conf
  NGINX_CONFS=$(find /opt/nginxproxymanager -type f -name "*.conf")
  for NGINX_CONF in $NGINX_CONFS; do
    sed -i 's+include conf.d+include /etc/nginx/conf.d+g' "$NGINX_CONF"
  done

  mkdir -p /var/www/html /etc/nginx/logs
  cp -r /opt/nginxproxymanager/docker/rootfs/var/www/html/* /var/www/html/
  cp -r /opt/nginxproxymanager/docker/rootfs/etc/nginx/* /etc/nginx/
  cp /opt/nginxproxymanager/docker/rootfs/etc/letsencrypt.ini /etc/letsencrypt.ini
  cp /opt/nginxproxymanager/docker/rootfs/etc/logrotate.d/nginx-proxy-manager /etc/logrotate.d/nginx-proxy-manager
  ln -sf /etc/nginx/nginx.conf /etc/nginx/conf/nginx.conf
  rm -f /etc/nginx/conf.d/dev.conf

  mkdir -p /tmp/nginx/body \
    /run/nginx \
    /data/nginx \
    /data/custom_ssl \
    /data/logs \
    /data/access \
    /data/nginx/default_host \
    /data/nginx/default_www \
    /data/nginx/proxy_host \
    /data/nginx/redirection_host \
    /data/nginx/stream \
    /data/nginx/dead_host \
    /data/nginx/temp \
    /var/lib/nginx/cache/public \
    /var/lib/nginx/cache/private \
    /var/cache/nginx/proxy_temp

  chmod -R 777 /var/cache/nginx
  chown root /tmp/nginx

  if [ ! -f /data/nginx/dummycert.pem ] || [ ! -f /data/nginx/dummykey.pem ]; then
    $STD openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 -subj "/O=Nginx Proxy Manager/OU=Dummy Certificate/CN=localhost" -keyout /data/nginx/dummykey.pem -out /data/nginx/dummycert.pem
  fi

  mkdir -p /app/frontend/images
  cp -r /opt/nginxproxymanager/backend/* /app
  msg_ok "Set up Environment"

  msg_info "Building Frontend"
  export NODE_OPTIONS="--max_old_space_size=2048 --openssl-legacy-provider"
  cd /opt/nginxproxymanager/frontend
  
  # Ubuntu-specific: Install frontend build dependencies
  apt-get install -y libnss3-dev libgdk-pixbuf2.0-dev libgtk-3-dev libxss-dev
  
  # Replace node-sass with sass in package.json before installation
  sed -E -i 's/"node-sass" *: *"([^"]*)"/"sass": "\1"/g' package.json
  $STD yarn install --network-timeout 600000
  $STD yarn build
  cp -r /opt/nginxproxymanager/frontend/dist/* /app/frontend
  cp -r /opt/nginxproxymanager/frontend/public/images/* /app/frontend/images
  msg_ok "Built Frontend"

  msg_info "Initializing Backend"
  rm -rf /app/config/default.json
  if [ ! -f /app/config/production.json ]; then
    cat <<'EOF' >/app/config/production.json
{
  "database": {
    "engine": "knex-native",
    "knex": {
      "client": "sqlite3",
      "connection": {
        "filename": "/data/database.sqlite"
      }
    }
  }
}
EOF
  fi
  cd /app
  $STD yarn install --network-timeout 600000
  msg_ok "Initialized Backend"

  msg_info "Updating Certbot"
  # Ubuntu-specific: Use Snap for Certbot (recommended on Ubuntu)
  if ! command -v certbot &>/dev/null; then
    if command -v snap &>/dev/null; then
      snap install core
      snap refresh core
      snap install --classic certbot
      ln -s /snap/bin/certbot /usr/bin/certbot
    else
      # Fallback to APT installation
      apt-get install -y certbot python3-certbot-dns-cloudflare
    fi
  else
    # Update existing certbot
    if [[ -x /snap/bin/certbot ]]; then
      snap refresh certbot
    elif [[ -d /opt/certbot ]]; then
      $STD /opt/certbot/bin/pip install --upgrade pip setuptools wheel
      $STD /opt/certbot/bin/pip install --upgrade certbot certbot-dns-cloudflare
    fi
  fi

  # Configure OpenResty repository for Ubuntu
  UBUNTU_CODENAME=$(lsb_release -sc)
  [ -f /etc/apt/trusted.gpg.d/openresty.gpg ] || curl -fsSL https://openresty.org/package/pubkey.gpg | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/openresty.gpg
  
  cat > /etc/apt/sources.list.d/openresty.list <<EOF
deb http://openresty.org/package/ubuntu $UBUNTU_CODENAME main
EOF
  
  $STD apt update
  $STD apt -y install openresty
  
  # Install additional Ubuntu packages for better performance
  apt-get install -y \
    libssl-dev \
    zlib1g-dev \
    libpcre3-dev \
    libgd-dev \
    libgeoip-dev \
    libxslt1-dev
  
  msg_ok "Updated Certbot and Dependencies"

  msg_info "Starting Services"
  sed -i 's/user npm/user root/g; s/^pid/#pid/g' /usr/local/openresty/nginx/conf/nginx.conf
  sed -r -i 's/^([[:space:]]*)su npm npm/\1#su npm npm/g;' /etc/logrotate.d/nginx-proxy-manager
  
  # Ubuntu-specific: Configure systemd service limits
  if [[ -f /etc/systemd/system/npm.service ]]; then
    cat > /etc/systemd/system/npm.service.d/limits.conf <<EOF
[Service]
LimitNOFILE=65536
LimitNPROC=65536
EOF
    systemctl daemon-reload
  fi
  
  # Configure log rotation for Ubuntu
  if [[ ! -f /etc/logrotate.d/nginx-proxy-manager ]]; then
    cat > /etc/logrotate.d/nginx-proxy-manager <<EOF
/var/log/nginx/*.log {
  daily
  missingok
  rotate 14
  compress
  delaycompress
  notifempty
  create 0640 www-data adm
  sharedscripts
  postrotate
    [ -f /var/run/nginx.pid ] && kill -USR1 \$(cat /var/run/nginx.pid)
  endscript
}
EOF
  fi
  
  systemctl enable -q --now openresty
  systemctl enable -q --now npm
  systemctl restart openresty
  
  # Ubuntu-specific: Enable UFW firewall rules (if UFW is installed)
  if command -v ufw &>/dev/null; then
    ufw allow 80/tcp comment "NPM HTTP"
    ufw allow 443/tcp comment "NPM HTTPS"
    ufw allow 81/tcp comment "NPM Admin"
  fi
  
  msg_ok "Started Services"

  # Ubuntu-specific: Create maintenance script
  cat > /usr/local/bin/npm-maintenance <<'EOF'
#!/bin/bash
echo "Nginx Proxy Manager Maintenance Script"
echo "--------------------------------------"
echo "1. Check service status"
echo "2. View logs"
echo "3. Backup database"
echo "4. Restore database"
echo "5. Renew SSL certificates"
echo "6. Update NPM"
echo "Enter your choice: "
read choice

case $choice in
  1)
    systemctl status npm
    systemctl status openresty
    ;;
  2)
    journalctl -u npm -f
    ;;
  3)
    cp /data/database.sqlite /data/database.sqlite.backup.$(date +%Y%m%d_%H%M%S)
    echo "Database backed up"
    ;;
  4)
    echo "Restore from which backup? (enter filename): "
    read backupfile
    cp "$backupfile" /data/database.sqlite
    systemctl restart npm
    ;;
  5)
    certbot renew --nginx
    systemctl reload nginx
    ;;
  6)
    echo "Running update script..."
    bash "$0" update
    ;;
  *)
    echo "Invalid choice"
    ;;
esac
EOF
  chmod +x /usr/local/bin/npm-maintenance

  msg_ok "Updated successfully!"
  msg_info "Maintenance script created: /usr/local/bin/npm-maintenance"
  exit
}

# Initial setup function for Ubuntu
function ubuntu_optimized_setup() {
  msg_info "Performing Ubuntu-optimized setup"
  
  # Update package list
  apt-get update
  
  # Install Ubuntu-specific dependencies
  apt-get install -y \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    ufw \
    snapd
  
  # Configure timezone (optional)
  timedatectl set-timezone UTC
  
  # Optimize swap (for low-memory containers)
  if [[ $var_ram -lt 4096 ]]; then
    echo "vm.swappiness=10" >> /etc/sysctl.conf
    echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
    sysctl -p
  fi
  
  # Configure systemd journal to limit size
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/00-limits.conf <<EOF
[Journal]
SystemMaxUse=100M
RuntimeMaxUse=50M
EOF
  
  msg_ok "Ubuntu setup completed"
}

start

# Run Ubuntu optimization before building container
ubuntu_optimized_setup

build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized on Ubuntu!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:81${CL}"
echo -e "${INFO}${YW} Ubuntu-specific optimizations applied:${CL}"
echo -e "${TAB}${BGN}• Node.js 22 from Nodesource${CL}"
echo -e "${TAB}${BGN}• Systemd-resolved integration${CL}"
echo -e "${TAB}${BGN}• UFW firewall rules${CL}"
echo -e "${TAB}${BGN}• Optimized system limits${CL}"
echo -e "${TAB}${BGN}• Maintenance script: /usr/local/bin/npm-maintenance${CL}"