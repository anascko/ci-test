#!/bin/bash

# Redirect all outputs
exec > >(tee -i /tmp/mk-bootstrap.log) 2>&1

# Add wrapper to apt-get to avoid race conditions
# with cron jobs running 'unattended-upgrades' script
aptget_wrapper() {
	local apt_wrapper_timeout=300
	local start_time=$(date '+%s')
        local fin_time=$((start_time + apt_wrapper_timeout))
        while true; do
                if (( "$(date '+%s')" > fin_time )); then
                  echo "aptget_wrapper - ERROR: Timeout exceeded: ${apt_wrapper_timeout} s. Lock files are still not released. Terminating..."
                  exit 1
                fi
                if fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; then
                  echo "aptget_wrapper - INFO: Waiting while another apt/dpkg process releases locks..."
                  sleep 30
                  continue
                else
                  apt-get $@
                  break
                fi
              done
        }
echo "Preparing base OS ..."
which wget >/dev/null || (aptget_wrapper update; aptget_wrapper install -y wget)

echo "deb [arch=amd64] http://apt-mk.mirantis.com/xenial nightly salt extra" > /etc/apt/sources.list.d/mcp_salt.list
wget -O - http://apt-mk.mirantis.com/public.gpg | apt-key add -

echo "deb http://repo.saltstack.com/apt/ubuntu/16.04/amd64/2016.3 xenial main" > /etc/apt/sources.list.d/saltstack.list
wget -O - https://repo.saltstack.com/apt/ubuntu/16.04/amd64/2016.3/SALTSTACK-GPG-KEY.pub | apt-key add -

aptget_wrapper clean
aptget_wrapper update

echo "Installing salt master ..."
aptget_wrapper install -y reclass git
aptget_wrapper install -y salt-master


[ ! -d /etc/salt/master.d ] && mkdir -p /etc/salt/master.d
cat << 'EOF' > /etc/salt/master.d/master.conf
file_roots:
  base:
  - /usr/share/salt-formulas/env
pillar_opts: False
open_mode: True
reclass: &reclass
  storage_type: yaml_fs
  inventory_base_uri: /srv/salt/reclass
ext_pillar:
  - reclass: *reclass
master_tops:
  reclass: *reclass
EOF

reclass_branch='master'
reclass_address='https://gerrit.mcp.mirantis.net/salt-models/mcp-virtual-lab'

set -x
echo "Configuring reclass ..."
ssh-keyscan -H github.com >> ~/.ssh/known_hosts
if echo $reclass_branch | egrep -q "^refs"; then
	git clone $reclass_address /srv/salt/reclass
	cd /srv/salt/reclass
	git fetch $reclass_address $reclass_branch && git checkout FETCH_HEAD
	git submodule init
	git submodule update --recursive
	cd -
else
       git clone -b $reclass_branch --recurse-submodules $reclass_address /srv/salt/reclass
fi

mkdir -p /srv/salt/reclass/classes/service

mkdir -p /srv/salt/reclass/nodes/_generated

node_hostname="$(hostname -s)"
node_domain='local'
node_name="$(hostname -s)"
node_cluster=''
cluster_name='virtual-mcp11-ovs'

echo "
classes:
- cluster.$cluster_name.infra.config
parameters:
  _param:
    linux_system_codename: xenial
    reclass_data_revision: $reclass_branch
    reclass_data_repository: $reclass_address
    cluster_name: $cluster_name
    cluster_domain: $node_domain
  linux:
    system:
      name: $node_hostname
      domain: $node_domain
  reclass:
    storage:
      data_source:
        engine: local
" > /srv/salt/reclass/nodes/_generated/$node_hostname.$node_domain.yml

FORMULA_PATH=${FORMULA_PATH:-/usr/share/salt-formulas}
FORMULA_REPOSITORY=${FORMULA_REPOSITORY:-deb [arch=amd64] http://apt-mk.mirantis.com/xenial testing salt}
FORMULA_GPG=${FORMULA_GPG:-http://apt-mk.mirantis.com/public.gpg}

echo "Configuring salt master formulas ..."
which wget > /dev/null || (aptget_wrapper update; aptget_wrapper install -y wget)

echo "${FORMULA_REPOSITORY}" > /etc/apt/sources.list.d/mcp_salt.list
wget -O - "${FORMULA_GPG}" | apt-key add -

aptget_wrapper clean
aptget_wrapper update

[ ! -d /srv/salt/reclass/classes/service ] && mkdir -p /srv/salt/reclass/classes/service

declare -a formula_services=("linux" "reclass" "salt" "openssh" "ntp" "git" "nginx" "collectd" "sensu" "heka" "sphinx" "mysql" "grafana" "libvirt" "rsyslog" "memcached" "rabbitmq" "apache" "keystone" "glance" "nova" "neutron" "cinder" "heat" "horizon" "ironic" "tftpd-hpa" "bind" "powerdns" "designate")

echo -e "\nInstalling all required salt formulas\n"
aptget_wrapper install -y "${formula_services[@]/#/salt-formula-}"

for formula_service in "${formula_services[@]}"; do
	echo -e "\nLink service metadata for formula ${formula_service} ...\n"
	[ ! -L "/srv/salt/reclass/classes/service/${formula_service}" ] && \
	ln -s ${FORMULA_PATH}/reclass/service/${formula_service} /srv/salt/reclass/classes/service/${formula_service}
done

[ ! -d /srv/salt/env ] && mkdir -p /srv/salt/env
[ ! -L /srv/salt/env/prd ] && ln -s ${FORMULA_PATH}/env /srv/salt/env/prd

[ ! -d /etc/reclass ] && mkdir /etc/reclass
cat << 'EOF' > /etc/reclass/reclass-config.yml
storage_type: yaml_fs
pretty_print: True
output: yaml
inventory_base_uri: /srv/salt/reclass
EOF

echo "Configuring salt minion ..."
[ ! -d /etc/salt/minion.d ] && mkdir -p /etc/salt/minion.d
echo " 
id: ${node_name}.${node_domain}
master: 127.0.0.1
" > /etc/salt/minion.d/minion.conf
aptget_wrapper install -y salt-minion

echo "Restarting services ..."
systemctl restart salt-master
systemctl restart salt-minion

echo "Showing system info and metadata ..."
salt-call --no-color grains.items
salt-call --no-color pillar.data

echo "Running complete state ..."
salt-call --no-color state.sls linux,openssh -l info
salt-call --no-color state.sls reclass -l info
salt-call --no-color state.sls salt.master.service -l info
salt-call --no-color state.sls salt.master
salt-call --no-color saltutil.sync_all
salt-call --no-color state.sls salt.api,salt.minion.ca -l info
systemctl restart salt-minion

set +x
