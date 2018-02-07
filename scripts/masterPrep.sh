#!/bin/bash
echo $(date) " - Starting Script"

set -e

curruser=$(ps -o user= -p $$ | awk '{print $1}')
echo "Executing script as user: $curruser"
echo "args: $*"

export STORAGEACCOUNT=$1
export SUDOUSER=$2
export LOCATION=$3

# Provide current variables if needed for troubleshooting
#set -o posix ; set
echo "Command line args: $@"

if yum list installed | grep epel | grep 7; then
    echo $(date) " - EPEL 7 already in place, skipping initial install"
else
    # Install EPEL repository
    echo $(date) " - Installing EPEL"

    yum -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm

    sed -i -e "s/^enabled=1/enabled=0/" /etc/yum.repos.d/epel.repo
fi

# Update system to latest packages and install dependencies
echo $(date) " - Update system to latest packages and install dependencies"

yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion kexec-tools sos psacct httpd-tools
yum -y install cloud-utils-growpart.noarch
yum -y update --exclude=WALinuxAgent

# Only install Ansible and pyOpenSSL on Master-000 Node
# python-passlib needed for metrics

if hostname -f|grep -e "-000" >/dev/null
then
   echo $(date) " - Installing Ansible, pyOpenSSL and python-passlib"
   yum -y --enablerepo=epel install ansible pyOpenSSL python-passlib
fi

if hostname -f|grep -e "bastion" >/dev/null
then
   echo $(date) " - Installing atomic-openshift-utils on bastion"
   echo $(date) " - Installing Ansible, pyOpenSSL and python-passlib"
   wget https://raw.githubusercontent.com/openshift/openshift-ansible/master/roles/openshift_repos/templates/CentOS-OpenShift-Origin37.repo.j2 -O /etc/yum.repos.d/CentOS-OpenShift-Origin37.repo
   wget https://raw.githubusercontent.com/openshift/openshift-ansible/master/roles/openshift_repos/files/origin/gpg_keys/openshift-ansible-CentOS-SIG-PaaS -O /etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-SIG-PaaS
   sed -i 's/enabled={.*/enabled=0/g' /etc/yum.repos.d/CentOS-OpenShift-Origin37.repo
   yum -y install atomic-openshift-utils ansible pyOpenSSL python-passlib
fi

# Install java to support metrics
echo $(date) " - Installing Java"

yum -y install java-1.8.0-openjdk-headless

# Grow Root File System
echo $(date) " - Grow Root FS"

rootdev=`findmnt --target / -o SOURCE -n`
rootdrivename=`lsblk -no pkname $rootdev`
rootdrive="/dev/"$rootdrivename
majorminor=`lsblk  $rootdev -o MAJ:MIN | tail -1`
part_number=${majorminor#*:}

growpart $rootdrive $part_number -u on
xfs_growfs $rootdev

# Install Docker 1.12.x
echo $(date) " - Installing Docker 1.12.x"

yum -y install docker
sed -i -e "s#^OPTIONS='--selinux-enabled'#OPTIONS='--selinux-enabled --insecure-registry 172.30.0.0/16'#" /etc/sysconfig/docker

# Create thin pool logical volume for Docker
echo $(date) " - Creating thin pool logical volume for Docker and staring service"

DOCKERVG=$( parted -m /dev/sda print all 2>/dev/null | grep unknown | grep /dev/sd | cut -d':' -f1 )

echo "DEVS=${DOCKERVG}" >> /etc/sysconfig/docker-storage-setup
echo "VG=docker-vg" >> /etc/sysconfig/docker-storage-setup
docker-storage-setup
if [ $? -eq 0 ]
then
   echo "Docker thin pool logical volume created successfully"
else
   echo "Error creating logical volume for Docker"
   exit 5
fi

# Enable and start Docker services

systemctl enable docker
systemctl start docker

# Create Storage Class yml files on MASTER-000

if hostname -f|grep -- "-000" >/dev/null
then
cat <<EOF > /home/${SUDOUSER}/scunmanaged.yml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: generic
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/azure-disk
parameters:
  location: ${LOCATION}
  storageAccount: ${STORAGEACCOUNT}
EOF

cat <<EOF > /home/${SUDOUSER}/scmanaged.yml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: generic
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/azure-disk
parameters:
  kind: managed
  location: ${LOCATION}
  storageaccounttype: Premium_LRS
EOF

fi

echo $(date) " - Script Complete"
