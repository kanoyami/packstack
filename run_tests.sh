#!/bin/bash -ex
# Copyright 2015 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

export PATH=$PATH:/usr/local/sbin:/usr/sbin

SCENARIO=${SCENARIO:-scenario001}

# We could want to override the default repositories or install behavior
INSTALL_FROM_SOURCE=${INSTALL_FROM_SOURCE:-true}
MANAGE_REPOS=${MANAGE_REPOS:-true}
DELOREAN=${DELOREAN:-http://trunk.rdoproject.org/centos7-mitaka/current-passed-ci/delorean.repo}
DELOREAN_DEPS=${DELOREAN_DEPS:-http://trunk.rdoproject.org/centos7-mitaka/delorean-deps.repo}
ADDITIONAL_ARGS=${ADDITIONAL_ARGS:-}
# If logs should be retrieved automatically
COPY_LOGS=${COPY_LOGS:-true}

if [ $(id -u) != 0 ]; then
    SUDO='sudo'

    # Packstack will connect as root to localhost, set-up the keypair and sshd
    ssh-keygen -t rsa -C "packstack-integration-test" -N "" -f ~/.ssh/id_rsa

    $SUDO mkdir -p /root/.ssh
    cat ~/.ssh/id_rsa.pub | $SUDO tee -a /root/.ssh/authorized_keys
    $SUDO chmod 0600 /root/.ssh/authorized_keys
    $SUDO sed -i 's/^PermitRootLogin no/PermitRootLogin without-password/g' /etc/ssh/sshd_config
    $SUDO service sshd restart
fi

# Sometimes keystone admin port is used as ephemeral port for other connections and gate jobs fail with httpd error 'Address already in use'.
# We reserve port 35357 at the beginning of the job execution to mitigate this issue as much as possible.
# Similar hack is done in devstack https://github.com/openstack-dev/devstack/blob/master/tools/fixup_stuff.sh#L53-L68

# Get any currently reserved ports, strip off leading whitespace
keystone_port=35357
reserved_ports=$(sysctl net.ipv4.ip_local_reserved_ports | awk -F'=' '{print $2;}' | sed 's/^ //')

if [[ -z "${reserved_ports}" ]]; then
    $SUDO sysctl -w net.ipv4.ip_local_reserved_ports=${keystone_port}
else
    $SUDO sysctl -w net.ipv4.ip_local_reserved_ports=${keystone_port},${reserved_ports}
fi

# Make swap configuration consistent
# TODO: REMOVE ME
# https://review.openstack.org/#/c/300122/
source ./tools/fix_disk_layout.sh

# Bump ulimit to avoid too many open file errors
echo "${USER} soft nofile 65536" | $SUDO tee -a /etc/security/limits.conf
echo "${USER} hard nofile 65536" | $SUDO tee -a /etc/security/limits.conf
echo "root soft nofile 65536" | $SUDO tee -a /etc/security/limits.conf
echo "root hard nofile 65536" | $SUDO tee -a /etc/security/limits.conf

# Setup repositories
if [ "${MANAGE_REPOS}" = true ]; then
    $SUDO curl -L ${DELOREAN} -o /etc/yum.repos.d/delorean.repo
    $SUDO curl -L ${DELOREAN_DEPS} -o /etc/yum.repos.d/delorean-deps.repo
fi

# Install dependencies
$SUDO yum -y install puppet \
                     yum-plugin-priorities \
                     iproute \
                     dstat \
                     python-setuptools \
                     openssl-devel \
                     python-devel \
                     libffi-devel \
                     libxml2-devel \
                     libxslt-devel \
                     libyaml-devel \
                     ruby-devel \
                     openstack-selinux \
                     policycoreutils \
                     wget \
                     "@Development Tools"

# Don't assume pip is installed
which pip || $SUDO easy_install pip

# Try to use pre-cached cirros images, if available, otherwise download them
rm -rf /tmp/cirros
mkdir /tmp/cirros

if [ -f ~/cache/files/cirros-0.3.4-x86_64-uec.tar.gz ]; then
    tar -xzvf ~/cache/files/cirros-0.3.4-x86_64-uec.tar.gz -C /tmp/cirros/
else
    echo "No pre-cached uec archive found, downloading..."
    wget --tries=10 http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-uec.tar.gz -P /tmp/cirros/
    tar -xzvf /tmp/cirros/cirros-0.3.4-x86_64-uec.tar.gz -C /tmp/cirros/
fi
if [ -f ~/cache/files/cirros-0.3.4-x86_64-disk.img ]; then
    cp -p ~/cache/files/cirros-0.3.4-x86_64-disk.img /tmp/cirros/
else
    echo "No pre-cached disk image found, downloading..."
    wget --tries=10 http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img -P /tmp/cirros/
fi
echo "Using pre-cached images:"
find /tmp/cirros -type f -printf "%m %n %u %g %s  %t" -exec md5sum \{\} \;

# TO-DO: Packstack should handle Hiera and Puppet configuration, so that it works
# no matter the environment
$SUDO su -c 'cat > /etc/puppet/puppet.conf <<EOF
[main]
    logdir = /var/log/puppet
    rundir = /var/run/puppet
    ssldir = $vardir/ssl
    hiera_config = /etc/puppet/hiera.yaml

[agent]
    classfile = $vardir/classes.txt
    localconfig = $vardir/localconfig
EOF'
$SUDO su -c 'cat > /etc/puppet/hiera.yaml <<EOF
---
:backends:
  - yaml
:yaml:
  :datadir: /placeholder
:hierarchy:
  - common
  - defaults
  - "%{clientcert}"
  - "%{environment}"
  - global
EOF'

# To make sure wrong config files are not used
if [ -d /home/jenkins/.puppet ]; then
  $SUDO rm -f /home/jenkins/.puppet
fi
$SUDO puppet config set hiera_config /etc/puppet/hiera.yaml

# Setup dstat for resource usage tracing
if type "dstat" 2>/dev/null; then
  $SUDO dstat -tcmndrylpg \
              --top-cpu-adv \
              --top-io-adv \
              --nocolor | $SUDO tee -a /var/log/dstat.log > /dev/null &
fi

# Setup packstack
if [ "${INSTALL_FROM_SOURCE}" = true ]; then
  $SUDO pip install .
  $SUDO python setup.py install_puppet_modules
else
  $SUDO yum -y install openstack-packstack
fi

# Generate configuration from selected scenario and run it
source ./tests/${SCENARIO}.sh
result=$?

# Print output and generate subunit if results exist
if [ -d /var/lib/tempest ]; then
    pushd /var/lib/tempest
    $SUDO .tox/tempest/bin/testr last || true
    $SUDO bash -c ".tox/tempest/bin/testr last --subunit > /var/tmp/packstack/latest/testrepository.subunit" || true
    popd
fi

if [ "${COPY_LOGS}" = true ]; then
    source ./tools/copy-logs.sh
    recover_default_logs
fi

if [ "${FAILURE}" = true ]; then
    exit 1
fi

exit $result
