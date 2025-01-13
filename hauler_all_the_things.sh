#!/bin/bash

# mkdir ${TMPDIR}/hauler/; cd ${TMPDIR}/hauler; curl -#OL https://raw.githubusercontent.com/clemenko/rke_airgap_install/main/hauler_all_the_things.sh && chmod 755 hauler_all_the_things.sh

# test script
# ./hauler_all_the_things.sh build && echo "0.0.0.0 docker.io index.docker.io quay.io gcr.io" >> /etc/hosts && ./hauler_all_the_things.sh control && source ~/.bashrc && ./hauler_all_the_things.sh longhorn && sleep 45 && ./hauler_all_the_things.sh rancher && sleep 30 && ./hauler_all_the_things.sh neuvector

# -----------
# this script is designed to bootstrap a POC cluster using Hauler
# this is NOT meant for production!
# -----------

set -ebpf

# application domain name
export DOMAIN=awesome.sauce
export LOGIN='' # Set to your docker.io ID to enable login and account usage capacity.
export TMPDIR=/var/tmp
export HAULER_BIN=/usr/local/bin/hauler

######  NO MOAR EDITS #######
# color
export RED='\x1b[0;31m'
export GREEN='\x1b[32m'
export BLUE='\x1b[34m'
export YELLOW='\x1b[33m'
export NO_COLOR='\x1b[0m'

# set functions for debugging/logging
function info { echo -e "$GREEN[info]$NO_COLOR $1" ;  }
function warn { echo -e "$YELLOW[warn]$NO_COLOR $1" ; }
function fatal { echo -e "$RED[error]$NO_COLOR $1" ; exit 1 ; }
function info_ok { echo -e "$GREEN" "ok" "$NO_COLOR" ; }

export PATH=$PATH:/usr/local/bin

# set server Ip here or from the command line
export server=$2

# el version
export EL_ver=  #set to el8 or el9 or the script will figure it out
if type rpm > /dev/null 2>&1 ; then export EL=${EL_ver:-$(rpm -q --queryformat '%{RELEASE}' rpm | grep -o "el[[:digit:]]" )} ; fi

if [ "$1" != "build" ] && [ $(uname) != "Darwin" ] ; then export serverIp=${server:-$(hostname -I | awk '{ print $1 }')} ; fi

if [ $(whoami) != "root" ] && ([ "$1" = "control" ] || [ "$1" = "worker" ] || [ "$1" = "serve" ] || [ "$1" = "neuvector" ] || [ "$1" = "longhorn" ] || [ "$1" = "rancher" ] || [ "$1" = "validate" ])  ; then fatal "please run $0 as root"; fi

################################# build ################################
function build () {

  info "checking for sudo / openssl / hauler / zstd / rsync / jq / helm"

  echo -e -n "checking sudo "
  command -v sudo > /dev/null 2>&1 || { echo -e -n "$RED" " ** sudo not found, installing ** ""$NO_COLOR"; yum install sudo -y > /dev/null 2>&1; }
  info_ok

  echo -e -n "checking openssl "
  command -v openssl > /dev/null 2>&1 || { echo -e -n "$RED" " ** openssl not found, installing ** ""$NO_COLOR"; yum install openssl -y > /dev/null 2>&1; }
  info_ok

  echo -e -n "checking rsync "
  command -v rsync > /dev/null 2>&1 || { echo -e -n "$RED" " ** rsync not found, installing ** ""$NO_COLOR"; yum install rsync -y > /dev/null 2>&1; }
  info_ok

  echo -e -n "checking zstd "
  command -v zstd > /dev/null 2>&1 || { echo -e -n "$RED" " ** zstd not found, installing ** ""$NO_COLOR"; yum install zstd -y > /dev/null 2>&1; }
  info_ok

  echo -e -n "checking helm "
  command -v helm > /dev/null 2>&1 || { echo -e -n "$RED" " ** helm was not found, installing ** ""$NO_COLOR"; curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash  > /dev/null 2>&1; }
  info_ok

  # get hauler if needed
  echo -e -n "checking hauler "
  command -v ${HAULER_BIN} >/dev/null 2>&1 || { echo -e -n "$RED" " ** hauler was not found, installing ** ""$NO_COLOR"; curl -sfL https://get.hauler.dev | bash  > /dev/null 2>&1; }
  info_ok

  # get jq if needed
  echo -e -n "checking jq "
  command -v jq >/dev/null 2>&1 || { echo -e -n "$RED" " ** jq was not found, installing ** ""$NO_COLOR"; yum install epel-release -y  > /dev/null 2>&1; yum install -y jq > /dev/null 2>&1; }
  info_ok

  mkdir -p ${TMPDIR}/hauler
  cd ${TMPDIR}/hauler

  # Permit user to use Docker login to the repositories to bypass login limits if imposed.
  if [ ! -z "${LOGIN}" ] ; then
    LOGIN_PW=""
    read -sp "Need login to docker.com for \"${LOGIN}\": " LOGIN_PW
    ${HAULER_BIN} login docker.io -u ${LOGIN} -p "${LOGIN_PW}"
    unset LOGIN_PW
  fi

  info "creating hauler manifest"
  # versions
  export dzver=$(curl -s https://dzver.rfed.io/json)
  export RKE_VERSION=$(echo $dzver | jq -r '."rke2 stable"' | sed 's/v//')
  export CERT_VERSION=$(echo $dzver | jq -r '."cert-manager"') 
  export RANCHER_VERSION=$(echo $dzver | jq -r '."rancher"')
  export LONGHORN_VERSION=$(echo $dzver | jq -r '."longhorn"')
  #export NEU_VERSION=$(echo $dzver | jq -r '."neuvector"')
  # neuvector chart has different version than code
  export NEU_VERSION=$(curl -s https://api.github.com/repos/neuvector/neuvector-helm/releases/latest | jq -r .tag_name)

  # temp dir
  mkdir -p hauler_temp

  # repod
  helm repo add jetstack https://charts.jetstack.io --force-update > /dev/null 2>&1
  helm repo add longhorn https://charts.longhorn.io --force-update> /dev/null 2>&1
  helm repo add neuvector https://neuvector.github.io/neuvector-helm/ --force-update> /dev/null 2>&1

  # images
cat << EOF > airgap_hauler.yaml
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Images
metadata:
  name: rancher-images
  annotations:
  # hauler.dev/key: <cosign public key>
    hauler.dev/platform: linux/amd64
  # hauler.dev/registry: <registry>
spec:       
  images:
EOF

  for i in $(helm template jetstack/cert-manager --version $CERT_VERSION | awk '$1 ~ /image:/ {print $2}' | sed 's/\"//g'); do echo "    - name: "$i >> airgap_hauler.yaml; done
  for i in $(helm template neuvector/core --version $NEU_VERSION | awk '$1 ~ /image:/ {print $2}' | sed -e 's/\"//g'); do echo "    - name: "$i >> airgap_hauler.yaml; done
  for i in $(curl -sL https://github.com/longhorn/longhorn/releases/download/$LONGHORN_VERSION/longhorn-images.txt); do echo "    - name: "$i >> airgap_hauler.yaml; done
  for i in $(curl -sL https://github.com/rancher/rke2/releases/download/v$RKE_VERSION%2Brke2r1/rke2-images-all.linux-amd64.txt|grep -v "sriov\|cilium\|vsphere"); do echo "    - name: "$i >> airgap_hauler.yaml ; done

  curl -sL https://github.com/rancher/rancher/releases/download/$RANCHER_VERSION/rancher-images.txt -o hauler_temp/orig-rancher-images.txt
  sed -E '/neuvector|minio|gke|aks|eks|sriov|harvester|mirrored|longhorn|thanos|tekton|istio|hyper|jenkins|windows/d' hauler_temp/orig-rancher-images.txt > hauler_temp/cleaned-rancher-images.txt
  
  # capi fixes
  grep cluster-api hauler_temp/orig-rancher-images.txt >> hauler_temp/cleaned-rancher-images.txt
  grep kubectl hauler_temp/orig-rancher-images.txt >> hauler_temp/cleaned-rancher-images.txt
    
  # get latest version
  for i in $(cat hauler_temp/cleaned-rancher-images.txt|awk -F: '{print $1}'); do 
    grep -w "$i" hauler_temp/cleaned-rancher-images.txt | sort -Vr| head -1 >> hauler_temp/rancher-unsorted.txt
  done

  # final sort
  sort -u hauler_temp/rancher-unsorted.txt > hauler_temp/rancher-images.txt

  # kubectl fix
  echo "rancher/kubectl:v1.20.2" >> hauler_temp/rancher-images.txt

  # shell fix
  echo "rancher/shell:v0.1.24" >> hauler_temp/rancher-images.txt

    # mirrored ingress nginx fix
  grep mirrored-ingress-nginx hauler_temp/orig-rancher-images.txt >> hauler_temp/rancher-images.txt

  for i in $(cat hauler_temp/rancher-images.txt); do echo "    - name: "$i >> airgap_hauler.yaml; done

  rm -rf hauler_temp

cat << EOF >> airgap_hauler.yaml
---
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Charts
metadata:
  name: rancher-charts
spec:
  charts:
    - name: rancher
      repoURL: https://releases.rancher.com/server-charts/latest
      version: $RANCHER_VERSION
    - name: cert-manager
      repoURL: https://charts.jetstack.io
      version: $CERT_VERSION
    - name: longhorn
      repoURL: https://charts.longhorn.io
      version: $LONGHORN_VERSION
    - name: core
      repoURL: https://neuvector.github.io/neuvector-helm/
      version: $NEU_VERSION
---
apiVersion: content.hauler.cattle.io/v1alpha1
kind: Files
metadata:
  name: rancher-files
spec:
  files:
    - path: https://github.com/rancher/rke2-packaging/releases/download/v$RKE_VERSION%2Brke2r1.stable.0/rke2-common-$RKE_VERSION.rke2r1-0.$EL.x86_64.rpm
    - path: https://github.com/rancher/rke2-packaging/releases/download/v$RKE_VERSION%2Brke2r1.stable.0/rke2-agent-$RKE_VERSION.rke2r1-0.$EL.x86_64.rpm
    - path: https://github.com/rancher/rke2-packaging/releases/download/v$RKE_VERSION%2Brke2r1.stable.0/rke2-server-$RKE_VERSION.rke2r1-0.$EL.x86_64.rpm
    - path: https://github.com/rancher/rke2-selinux/releases/download/v0.18.stable.1/rke2-selinux-0.18-1.$EL.noarch.rpm
    - path: https://get.helm.sh/helm-$(curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r .tag_name)-linux-amd64.tar.gz
    - path: https://raw.githubusercontent.com/clemenko/rke_airgap_install/main/hauler_all_the_things.sh
  # - path: https://download.rockylinux.org/pub/rocky/9/isos/x86_64/Rocky-9.4-x86_64-dvd.iso
EOF

  echo -n "  - created airgap_hauler.yaml"; info_ok

  warn "- hauler store sync - will take some time..."
  ${HAULER_BIN} store sync -f ${TMPDIR}/hauler/airgap_hauler.yaml || { fatal "hauler failed to sync - check airgap_hauler.yaml for errors" ; }
  echo -n "  - synced"; info_ok
  
  # copy hauler binary
  rsync -avP ${HAULER_BIN} ${TMPDIR}/hauler/hauler > /dev/null 2>&1

  warn "- compressing all the things - will take a minute"
  tar -I zstd -cf ${TMPDIR}/hauler_airgap_$(date '+%m_%d_%y').zst $(ls) > /dev/null 2>&1
  echo -n "  - created ${TMPDIR}/hauler_airgap_$(date '+%m_%d_%y').zst "; info_ok

  echo -e "---------------------------------------------------------------------------"
  echo -e $BLUE"    move file to other network..."
  echo -e $YELLOW"    then uncompress with : "$NO_COLOR
  echo -e "      mkdir ${TMPDIR}/hauler && yum install -y zstd"
  echo -e "      tar -I zstd -vxf hauler_airgap_$(date '+%m_%d_%y').zst -C ${TMPDIR}/hauler"
  echo -e "      $0 control"
  echo -e "---------------------------------------------------------------------------"

}

################################# hauler_setup ################################
function hauler_setup () {

# check that the script is in the correct dir

if [ ! -d ${TMPDIR}/hauler ]; then 
  fatal Please create ${TMPDIR}/hauler and unpack the zst there.
fi

# make sure it is not running
if [ $(ss -tln | grep "8080\|5000" | wc -l) != 2 ]; then

  info "setting up hauler"

  # install
  if [ ! -f ${HAULER_BIN} ]; then  install -m 755 hauler /usr/local/bin || fatal "Failed to Install Hauler to /usr/local/bin" ; fi

  # load
#  ${HAULER_BIN} store load ${TMPDIR}/hauler/haul.tar.zst || fatal "Failed to load hauler store"

  # add systemd file
cat << EOF > /etc/systemd/system/hauler@.service
# /etc/systemd/system/hauler.service
[Unit]
Description=Hauler Serve %I Service

[Service]
Environment="HOME=${TMPDIR}/hauler/"
ExecStart=/usr/local/bin/hauler store serve %i -s ${TMPDIR}/hauler/store
WorkingDirectory=${TMPDIR}/hauler/
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  #reload daemon
  systemctl daemon-reload

  # start fileserver
  mkdir -p ${TMPDIR}/hauler/fileserver
  systemctl enable hauler@fileserver > /dev/null 2>&1 
  systemctl start hauler@fileserver || fatal "hauler fileserver did not start"
  echo -n " - fileserver started"; info_ok

  sleep 30

  # start reg
  systemctl enable hauler@registry > /dev/null 2>&1 
  systemctl start hauler@registry || fatal "hauler registry did not start"
  echo -n " - registry started"; info_ok

  sleep 30

  # wait for fileserver to come up.
  until [ $(ls -1 ${TMPDIR}/hauler/fileserver/ | wc -l) -gt 9 ]; do sleep 2; done
 
  until ${HAULER_BIN} store info > /dev/null 2>&1; do sleep 5; done

  # generate an index file
  ${HAULER_BIN} store info > ${TMPDIR}/hauler/fileserver/_hauler_index.txt || fatal "hauler store is having issues - check ${TMPDIR}/hauler/fileserver/_hauler_index.txt"

  # add dvd iso
  # mkdir -p ${TMPDIR}/hauler/fileserver/dvd
  # mount -o loop Rocky-8.9-x86_64-dvd1.iso ${TMPDIR}/fileserver/dvd

  # create yum repo file
  cat << EOF > ${TMPDIR}/hauler/fileserver/hauler.repo
[hauler]
name=Hauler Air Gap Server
baseurl=http://$serverIp:8080
enabled=1
gpgcheck=0
EOF

# add for dvd support
#[rocky-dvd-base]
#name=Rocky DVD BaseOS
#baseurl=http://$serverIp:8080/dvd/BaseOS/
#enabled=1
#gpgcheck=0
#[rocky-dvd-app]
#name=Rocky DVD AppStream
#baseurl=http://$serverIp:8080/dvd/AppStream/
#enabled=1
#gpgcheck=0

  # install createrepo
  if yum list installed createrepo_c > /dev/null 2>&1; then
    echo "createrepo is already installed"
  else
    yum install -y createrepo  > /dev/null 2>&1 || fatal "createrepo was not installed, please install"
  fi
  
  # create repo for rancher rpms
  createrepo ${TMPDIR}/hauler/fileserver > /dev/null 2>&1 || fatal "createrepo did not finish correctly, please run manually \"createrepo ${TMPDIR}/hauler/fileserver\""

fi

}

################################# base ################################
function base () {

  # install all the base bits.
  info "updating kernel settings"
  cat << EOF > /etc/sysctl.conf
# SWAP settings
vm.swappiness=0
vm.panic_on_oom=0
vm.overcommit_memory=1
kernel.panic=10
kernel.panic_on_oops=1
vm.max_map_count = 262144

# Have a larger connection range available
net.ipv4.ip_local_port_range=1024 65000

# Increase max connection
net.core.somaxconn=10000

# Reuse closed sockets faster
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15

# The maximum number of "backlogged sockets".  Default is 128.
net.core.somaxconn=4096
net.core.netdev_max_backlog=4096

# 16MB per socket - which sounds like a lot,
# but will virtually never consume that much.
net.core.rmem_max=16777216
net.core.wmem_max=16777216

# Various network tunables
net.ipv4.tcp_max_syn_backlog=20480
net.ipv4.tcp_max_tw_buckets=400000
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_syn_retries=2
net.ipv4.tcp_synack_retries=2
net.ipv4.tcp_wmem=4096 65536 16777216

# ARP cache settings for a highly loaded docker swarm
net.ipv4.neigh.default.gc_thresh1=8096
net.ipv4.neigh.default.gc_thresh2=12288
net.ipv4.neigh.default.gc_thresh3=16384

# ip_forward and tcp keepalive for iptables
net.ipv4.tcp_keepalive_time=600
net.ipv4.ip_forward=1

# monitor file system events
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=1048576
EOF
sysctl -p > /dev/null 2>&1

  # disable firewalld
  if yum list installed firewalld > /dev/null 2>&1; then 
    yum remove -y firewalld > /dev/null 2>&1 || fatal "firewalld could not be disabled"
    warn "firewalld was removed"
  else
    info "firewalld not installed"
  fi

  info "installing base packages"
  base_packages="zstd iptables container-selinux libnetfilter_conntrack libnfnetlink libnftnl policycoreutils-python-utils cryptsetup iscsi-initiator-utils"
  for pkg in $base_packages; do
      if ! rpm -q $pkg > /dev/null 2>&1; then
          echo "Installing $pkg..."
          yum install -y $pkg > /dev/null 2>&1 || fatal "$pkg was not installed, please install"
      else
          echo "$pkg is already installed"
      fi
  done

  systemctl enable --now iscsid > /dev/null 2>&1
  echo -e "[keyfile]\nunmanaged-devices=interface-name:cali*;interface-name:flannel*" > /etc/NetworkManager/conf.d/rke2-canal.conf

  info "adding yum repo"
    # add repo 
  curl -sfL http://$serverIp:8080/hauler.repo -o /etc/yum.repos.d/hauler.repo || fatal "check `http://$serverIp:8080/hauler.repo` to ensure the hauler.repo exists"

    # set registry override
  mkdir -p /etc/rancher/rke2/
  echo -e "mirrors:\n  \"*\":\n    endpoint:\n      - http://$serverIp:5000" > /etc/rancher/rke2/registries.yaml 

  # clean all the yums
  yum clean all  > /dev/null 2>&1

}

################################# deploy control ################################
function deploy_control () {
  # this is for the first node

  # wait and add link
  grep -qxF 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH=$PATH:/usr/local/bin/:/var/lib/rancher/rke2/bin/' ~/.bashrc || echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH=$PATH:/usr/local/bin/:/var/lib/rancher/rke2/bin/' >> ~/.bashrc
  source ~/.bashrc

  # set up hauler services
  hauler_setup

  # kernel and package stuff
  base

  info "installing rke2"

  # add etcd user
  if ! grep etcd /etc/passwd > /dev/null 2>&1 ; then useradd -r -c "etcd user" -s /sbin/nologin -M etcd -U ; fi 
  
  # create stig config files
  mkdir -p /etc/rancher/rke2/ /var/lib/rancher/rke2/server/manifests/ /var/lib/rancher/rke2/agent/images
  echo -e "#profile: cis-1.23\nselinux: true\nsecrets-encryption: true\ntoken: bootstrapAllTheThings\nwrite-kubeconfig-mode: 0600\nkube-controller-manager-arg:\n- bind-address=127.0.0.1\n- use-service-account-credentials=true\n- tls-min-version=VersionTLS12\n- tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384\nkube-scheduler-arg:\n- tls-min-version=VersionTLS12\n- tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384\nkube-apiserver-arg:\n- tls-min-version=VersionTLS12\n- tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384\n- authorization-mode=RBAC,Node\n- anonymous-auth=false\n- audit-policy-file=/etc/rancher/rke2/audit-policy.yaml\n- audit-log-mode=blocking-strict\n- audit-log-maxage=30\nkubelet-arg:\n- protect-kernel-defaults=true\n- read-only-port=0\n- authorization-mode=Webhook" > /etc/rancher/rke2/config.yaml

  # set up audit policy file
  echo -e "apiVersion: audit.k8s.io/v1\nkind: Policy\nmetadata:\n  name: rke2-audit-policy\nrules:\n  - level: Metadata\n    resources:\n    - group: \"\"\n      resources: [\"secrets\"]\n  - level: RequestResponse\n    resources:\n    - group: \"\"\n      resources: [\"*\"]" > /etc/rancher/rke2/audit-policy.yaml

  # set up ssl passthrough for nginx
  echo -e "---\napiVersion: helm.cattle.io/v1\nkind: HelmChartConfig\nmetadata:\n  name: rke2-ingress-nginx\n  namespace: kube-system\nspec:\n  valuesContent: |-\n    controller:\n      config:\n        use-forwarded-headers: true\n      extraArgs:\n        enable-ssl-passthrough: true" > /var/lib/rancher/rke2/server/manifests/rke2-ingress-nginx-config.yaml

  # insall rke2 - stig'd
  yum install -y --disablerepo=* --enablerepo=hauler rke2-server rke2-common rke2-selinux > /dev/null 2>&1 || fatal "yum install rke2 packages didn't work. check the hauler fileserver service."
  systemctl enable --now rke2-server.service > /dev/null 2>&1 || fatal "rke2-server didn't start"

  until systemctl is-active -q rke2-server; do sleep 2; done

  # wait for cluster to be active
  until [ $(kubectl get node | grep Ready | wc -l) == 1 ]; do sleep 2; done
  info "cluster active"

  # install helm 
  info "installing helm"
  cd ${TMPDIR}/hauler
  curl -sfL http://$serverIp:8080/$(curl -sfL http://$serverIp:8080/ | grep helm | sed -e 's/<[^>]*>//g') | tar -zxvf - > /dev/null 2>&1
  install -m 755 linux-amd64/helm /usr/local/bin || fatal "Failed to install helm to /usr/local/bin"

  echo "------------------------------------------------------------------------------------"
  echo -e "  Run: $BLUE 'source ~/.bashrc' "$NO_COLOR
  echo    "  Run on the worker nodes"
  echo -e "  - '$BLUE curl -sfL http://$serverIp:8080/hauler_all_the_things.sh | bash -s -- worker $serverIp $NO_COLOR'"
  echo "------------------------------------------------------------------------------------"
}

################################# deploy worker ################################
function deploy_worker () {
  echo - deploy worker

  # base bits
  base

  # setup RKE2
  mkdir -p /etc/rancher/rke2/
  echo -e "server: https://$serverIp:9345\ntoken: bootstrapAllTheThings\nwrite-kubeconfig-mode: 0600\n#profile: cis-1.23\nkube-apiserver-arg:\n- \"authorization-mode=RBAC,Node\"\nkubelet-arg:\n- \"protect-kernel-defaults=true\" " > /etc/rancher/rke2/config.yaml
  
  # install rke2
  yum install -y rke2-agent rke2-common rke2-selinux > /dev/null 2>&1 || fatal "packages didn't install"
  systemctl enable --now rke2-agent.service > /dev/null 2>&1 || fatal "rke2-agent didn't start"
  info "worker node running"
}

################################# longhorn ################################
function longhorn () {
  # deploy longhorn with local helm/images
  info "deploying longhorn"
    helm upgrade -i longhorn oci://$serverIp:5000/hauler/longhorn --namespace longhorn-system --create-namespace --set ingress.enabled=true --set ingress.host=longhorn.$DOMAIN --plain-http
}

################################# neuvector ################################
function neuvector () {
  # deploy neuvector with local helm/images
  info "deploying neuvector"
  helm upgrade -i neuvector --namespace neuvector oci://$serverIp:5000/hauler/core --create-namespace  --set k3s.enabled=true --set k3s.runtimePath=/run/k3s/containerd/containerd.sock  --set manager.ingress.enabled=true --set controller.pvc.enabled=true --set manager.svc.type=ClusterIP --set manager.ingress.host=neuvector.$DOMAIN --set internal.certmanager.enabled=true --set cve.adapter.internal.certificate.secret=neuvector-internal --set enforcer.internal.certificate.secret=neuvector-internal --set cve.scanner.internal.certificate.secret=neuvector-internal  --set controller.internal.certificate.secret=neuvector-internal --plain-http
}

################################# rancher ################################
function rancher () {
  # deploy rancher with local helm/images
  info "deploying cert-manager"
  helm upgrade -i cert-manager oci://$serverIp:5000/hauler/cert-manager --version $(curl -sfL http://$serverIp:8080/_hauler_index.txt | grep hauler/cert | awk '{print $2}'| awk -F: '{print $2}') --namespace cert-manager --create-namespace --set crds.enabled=true --plain-http

  info "deploying rancher"
  helm upgrade -i rancher oci://$serverIp:5000/hauler/rancher --namespace cattle-system --create-namespace --set bootstrapPassword=bootStrapAllTheThings --set replicas=1 --set auditLog.level=2 --set auditLog.destination=hostPath --set useBundledSystemChart=true --set hostname=rancher.$DOMAIN --plain-http

  #gov logon message
export govmessage=$(cat <<EOF
You are accessing a U.S. Government (USG) Information System (IS) that is provided for USG-authorized use only.By using this IS (which includes any device attached to this IS), you consent to the following conditions:-The USG routinely intercepts and monitors communications on this IS for purposes including, but not limited to, penetration testing, COMSEC monitoring, network operations and defense, personnel misconduct (PM), law enforcement (LE), and counterintelligence (CI) investigations.-At any time, the USG may inspect and seize data stored on this IS.-Communications using, or data stored on, this IS are not private, are subject to routine monitoring, interception, and search, and may be disclosed or used for any USG-authorized purpose.-This IS includes security measures (e.g., authentication and access controls) to protect USG interests--not for your personal benefit or privacy.-Notwithstanding the above, using this IS does not constitute consent to PM, LE or CI investigative searching or monitoring of the content of privileged communications, or work product, related to personal representation or services by attorneys, psychotherapists, or clergy, and their assistants. Such communications and work product are private and confidential. See User Agreement for details.
EOF
)

  sleep 30 

   # class banners
cat <<EOF | kubectl apply -f -  > /dev/null 2>&1
apiVersion: management.cattle.io/v3
kind: Setting
metadata:
  name: ui-banners
value: '{"bannerHeader":{"background":"#007a33","color":"#ffffff","textAlignment":"center","fontWeight":null,"fontStyle":null,"fontSize":"14px","textDecoration":null,"text":"UNCLASSIFIED//FOUO"},"bannerFooter":{"background":"#007a33","color":"#ffffff","textAlignment":"center","fontWeight":null,"fontStyle":null,"fontSize":"14px","textDecoration":null,"text":"UNCLASSIFIED//FOUO"},"bannerConsent":{"background":"#ffffff","color":"#000000","textAlignment":"left","fontWeight":null,"fontStyle":null,"fontSize":"14px","textDecoration":false,"text":"$govmessage","button":"Accept"},"showHeader":"true","showFooter":"true","showConsent":"true"}'
EOF


  echo "   - bootstrap password = \"bootStrapAllTheThings\" "
}

################################# validate ################################
function validate () {
  info "showing all images"
  kubectl get pods -A -o jsonpath="{.items[*].spec.containers[*].image}" | tr -s '[[:space:]]' '\n' |sort | uniq -c
}

############################# usage ################################
function usage () {
  echo ""
  echo "-------------------------------------------------"
  echo ""
  echo -e $YELLOW" Script Usage: $0 { build | control | worker }"$NO_COLOR
  echo ""
  echo -e " $0$BLUE build$NO_COLOR # download and create the monster TAR "
  echo -e " $0$BLUE control$NO_COLOR # deploy on a control plane server"
  echo -e " $0$BLUE worker$NO_COLOR # deploy on a worker"
  echo "-------------------------------------------------"
  echo " $0 neuvector # deploy neuvector"
  echo " $0 longhorn # deploy longhorn"
  echo " $0 rancher # deploy rancher"
  echo " $0 validate # validate all the image locations"
  echo ""
  echo "-------------------------------------------------"
  echo ""
  echo -e $BLUE"Cluster Setup Steps:"$NO_COLOR
  echo -e $GREEN" - UNCLASS - $0 build"$NO_COLOR
  echo ""
  echo -e $RED" - Move the ZST file across the air gap"$NO_COLOR
  echo ""
  echo " - Build 3 vms with 4cpu and 8gb of ram"
  echo -e "   - On 1st node run, as $RED"root"$NO_COLOR:"
  echo -e "     -$BLUE mkdir ${TMPDIR}/hauler && tar -I zstd -vxf hauler_airgap_$(date '+%m_%d_%y').zst -C ${TMPDIR}/hauler"$NO_COLOR
  echo -e "     -$BLUE cd ${TMPDIR}/hauler; $0 control"$NO_COLOR
  echo ""
  echo -e "   - On 2nd, and 3rd nodes run, as $RED"root"$NO_COLOR:"
  echo -e "      -$BLUE curl -sfL http://$serverIp:8080/hauler_all_the_things.sh | bash -s -- worker $serverIp "$NO_COLOR
  echo ""
  echo " - Application Setup from 1st node install"
  echo -e "   - Longhorn : $0$BLUE longhorn"$NO_COLOR
  echo -e "   - Rancher : $0$BLUE rancher"$NO_COLOR
  echo -e "   - NeuVector : $0$BLUE neuvector"$NO_COLOR
  echo ""
  echo "-------------------------------------------------"
  echo ""
  exit 1
}

case "$1" in
        build ) build;;
        control) deploy_control;;
        worker) deploy_worker;;
        serve) hauler_setup;;
        neuvector) neuvector;;
        longhorn) longhorn;;
        rancher) rancher;;
        validate) validate;;
        *) usage;;
esac
