#!/bin/bash

# mkdir /opt/hauler/; cd /opt/hauler; curl -#OL https://raw.githubusercontent.com/clemenko/rke_airgap_install/main/hauler_all_the_things.sh && chmod 755 hauler_all_the_things.sh

# -----------
# this script is designed to bootstrap a POC cluster using Hauler
# this is NOT meant for production!
# -----------

set -ebpf

# application domain name
export DOMAIN=awesome.sauce
# set server Ip here or from the command line
export server=$2

######  NO MOAR EDITS #######
# color
export RED='\x1b[0;31m'
export GREEN='\x1b[32m'
export BLUE='\x1b[34m'
export YELLOW='\x1b[33m'
export NO_COLOR='\x1b[0m'

# set functions for debugging/logging
function info_ok { echo -e "$GREEN" "ok" "$NO_COLOR" && echo ; }
function info { echo -e "$GREEN[info]$NO_COLOR $1" ;  }
function warn { echo -e "$YELLOW[warn]$NO_COLOR $0: $1" ; }
function fatal { echo -e "$RED[error]$NO_COLOR $0: $1" ; exit 1 ; }

#export PATH=$PATH:/usr/local/bin

# el version
export EL=$(rpm -q --queryformat '%{RELEASE}' rpm | grep -o "el[[:digit:]]")

# check for root
if [ $(whoami) != "root" ] ; then fatal "please run $0 as root"; exit; fi

export serverIp=${server:-$(hostname -I | awk '{ print $1 }')}

################################# build ################################
function build () {

  info "checking for hauler / ztsd / jq / helm"
  command -v hauler >/dev/null 2>&1 || { warn "hauler was not found"; curl -sfL https://get.hauler.dev | bash > /dev/null 2>&1; }
  yum list installed zstd >/dev/null 2>&1 || { warn "ztsd was not found"; yum install zstd -y> /dev/null 2>&1; }
  command -v jq >/dev/null 2>&1 || { warn "jq was not found"; yum install -y epel-release ; yum install -y jq > /dev/null 2>&1; }
  command -v helm >/dev/null 2>&1 || { warn "helm was not found"; curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash > /dev/null 2>&1; } 
  echo -n "  - installed "; info_ok

  cd /opt/hauler

  info "creating hauler manifest"
  # versions
  export RKE_VERSION=$(curl -s https://update.rke2.io/v1-release/channels | jq -r '.data[] | select(.id=="stable") | .latest' | awk -F"+" '{print $1}'| sed 's/v//')
  export CERT_VERSION=$(curl -s https://api.github.com/repos/cert-manager/cert-manager/releases/latest | jq -r .tag_name)
  export RANCHER_VERSION=$(curl -s https://api.github.com/repos/rancher/rancher/releases/latest | jq -r .tag_name)
  export LONGHORN_VERSION=$(curl -s https://api.github.com/repos/longhorn/longhorn/releases/latest | jq -r .tag_name)
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
    - name: docker.io/redis:latest
    - name: docker.io/mongo:latest
    - name: docker.io/clemenko/flask_simple:latest
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
    - path: https://github.com/rancher/rke2-selinux/releases/download/v0.17.stable.1/rke2-selinux-0.17-1.$EL.noarch.rpm
    - path: https://get.helm.sh/helm-$(curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r .tag_name)-linux-amd64.tar.gz
    - path: https://raw.githubusercontent.com/clemenko/rke_airgap_install/main/flask.yaml
    - path: https://raw.githubusercontent.com/clemenko/rke_airgap_install/main/hauler_all_the_things.sh
EOF

  echo -n "  - created airgap_hauler.yaml"; info_ok

  info "- hauler store sync"
  hauler store sync -f /opt/hauler/airgap_hauler.yaml > /dev/null 2>&1 || { fatal "hauler failed to sync - check airgap_hauler.yaml for errors" ; }
  echo -n "  - synced"; info_ok

  info "- hauler store save"
  hauler store save -f /opt/hauler/haul.tar.zst > /dev/null 2>&1 || { fatal "hauler failed to save - run manually : $BLUE hauler store save -f /opt/hauler/haul.tar.zst $NO_COLOR" ; }
  echo -n "  - saved"; info_ok
  
  # cleanup
  rm -rf /opt/hauler/store /opt/hauler/airgap_hauler.yaml

  # copy hauler binary
  rsync -avP /usr/local/bin/hauler /opt/hauler/hauler > /dev/null 2>&1

  info "- compressing all the things"
  tar -I zstd -vcf /opt/hauler_airgap_$(date '+%m_%d_%y').zst $(ls) > /dev/null 2>&1
  echo -n "  - created /opt/hauler_airgap_$(date '+%m_%d_%y').zst "; info_ok

  echo -e "---------------------------------------------------------------------------"
  echo -e $BLUE"    move file to other network..."
  echo -e $YELLOW"    then uncompress with : "$NO_COLOR
  echo -e "      yum install -y zstd"
  echo -e "      mkdir /opt/hauler"
  echo -e "      tar -I zstd -vxf hauler_airgap_$(date '+%m_%d_%y').zst -C /opt/hauler"
  echo -e "---------------------------------------------------------------------------"

}

################################# hauler_setup ################################
function hauler_setup () {

# make sure it is not running
if [ $(ss -tln | grep "8080\|5000" | wc -l) != 2 ]; then


  info "setting up hauler"

  # install
  install -m 755 hauler /usr/local/bin || fatal "Failed to Install Hauler to /usr/local/bin"

  # load
  hauler store load /opt/hauler/haul.tar.zst || fatal "Failed to load hauler store"

  # add systemd file
cat << EOF > /etc/systemd/system/hauler@.service
# /etc/systemd/system/hauler.service
[Unit]
Description=Hauler Serve %I Service

[Service]
Environment="HOME=/opt/hauler/"
ExecStart=/usr/local/bin/hauler store serve %i
WorkingDirectory=/opt/hauler

[Install]
WantedBy=multi-user.target
EOF

  #reload daemon
  systemctl daemon-reload

  # start fileserver
  systemctl enable --now hauler@fileserver || fatal "hauler fileserver did not start"
  echo -n " - fileserver started"; info_ok

  sleep 5

  # start reg
  systemctl enable --now hauler@registry || fatal "hauler registry did not start"
  echo -n " - registry started"; info_ok

  # install createrepo
  yum install -y createrepo  > /dev/null 2>&1 || fatal "creaerepo was not installed, please install"
  
  # wait for fileserver to come up.
  until [ $(ls -1 /opt/hauler/store-files/ | grep rpm | wc -l) == 4 ]; do sleep 2; done

  createrepo /opt/hauler/store-files > /dev/null 2>&1
 
  # generate an index file
  hauler store info > /opt/hauler/store-files/_hauler_index.txt

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

  info "installing base packages"
  yum install -y zstd iptables container-selinux iptables libnetfilter_conntrack libnfnetlink libnftnl policycoreutils-python-utils cryptsetup iscsi-initiator-utils > /dev/null 2>&1
  systemctl enable --now iscsid > /dev/null 2>&1
  echo -e "[keyfile]\nunmanaged-devices=interface-name:cali*;interface-name:flannel*" > /etc/NetworkManager/conf.d/rke2-canal.conf
}

################################# deploy control ################################
function deploy_control () {
  # this is for the first node

  # set up hauler services
  hauler_setup

  # add repo 
cat << EOF > /etc/yum.repos.d/hauler.repo
[hauler]
name=Hauler Air Gap Server
baseurl=http://$serverIp:8080
enabled=1
gpgcheck=0
EOF

  # clean all the yums
  yum clean all  > /dev/null 2>&1

  # kernel and package stuff
  base

  info "installing rke2"
#  mkdir -p /opt/rancher/rke2
#  cd /opt/rancher/rke2

  # get bits
#  for i in $(curl -sfL http://$serverIp:8080/ |grep amd64 | grep rke2 | sed -e 's/<[^>]*>//g'); do
#   curl -sfLO http://$serverIp:8080/$i
#  done

  useradd -r -c "etcd user" -s /sbin/nologin -M etcd -U
  mkdir -p /etc/rancher/rke2/ /var/lib/rancher/rke2/server/manifests/ /var/lib/rancher/rke2/agent/images
  echo -e "#profile: cis-1.23\nselinux: true\nsecrets-encryption: true\ntoken: bootstrapAllTheThings\nwrite-kubeconfig-mode: 0600\nkube-controller-manager-arg:\n- bind-address=127.0.0.1\n- use-service-account-credentials=true\n- tls-min-version=VersionTLS12\n- tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384\nkube-scheduler-arg:\n- tls-min-version=VersionTLS12\n- tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384\nkube-apiserver-arg:\n- tls-min-version=VersionTLS12\n- tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384\n- authorization-mode=RBAC,Node\n- anonymous-auth=false\n- audit-policy-file=/etc/rancher/rke2/audit-policy.yaml\n- audit-log-mode=blocking-strict\n- audit-log-maxage=30\nkubelet-arg:\n- protect-kernel-defaults=true\n- read-only-port=0\n- authorization-mode=Webhook" > /etc/rancher/rke2/config.yaml

  # set up audit policy file
  echo -e "apiVersion: audit.k8s.io/v1\nkind: Policy\nmetadata:\n  name: rke2-audit-policy\nrules:\n  - level: Metadata\n    resources:\n    - group: \"\"\n      resources: [\"secrets\"]\n  - level: RequestResponse\n    resources:\n    - group: \"\"\n      resources: [\"*\"]" > /etc/rancher/rke2/audit-policy.yaml

  # set up ssl passthrough for nginx
  echo -e "---\napiVersion: helm.cattle.io/v1\nkind: HelmChartConfig\nmetadata:\n  name: rke2-ingress-nginx\n  namespace: kube-system\nspec:\n  valuesContent: |-\n    controller:\n      config:\n        use-forwarded-headers: true\n      extraArgs:\n        enable-ssl-passthrough: true" > /var/lib/rancher/rke2/server/manifests/rke2-ingress-nginx-config.yaml

  # set registry override
  echo -e "mirrors:\n  docker.io:\n    endpoint:\n      - http://$serverIp:5000\n  $serverIp:5000:\n    endpoint:\n      - http://$serverIp:5000" > /etc/rancher/rke2/registries.yaml

  # insall rke2 - stig'd
  yum install -y rke2-server rke2-common rke2-selinux > /dev/null 2>&1
  systemctl enable --now rke2-server.service > /dev/null 2>&1

  until systemctl is-active -q rke2-server; do sleep 2; done

  # wait and add link
  echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml PATH=$PATH:/var/lib/rancher/rke2/bin" >> ~/.bashrc
  ln -s /var/run/k3s/containerd/containerd.sock /var/run/containerd/containerd.sock
  source ~/.bashrc

  # wait for cluster to be active
  until [ $(kubectl get node | grep Ready | wc -l) == 1 ]; do sleep 2; done
  info "cluster active"

  # install helm 
  info "installing helm"
  cd /opt/hauler
  curl -sfL http://$serverIp:8080/$(curl -sfL http://$serverIp:8080/ | grep helm | sed -e 's/<[^>]*>//g') | tar -zxvf - > /dev/null 2>&1
  install -m 755 linux-amd64/helm /usr/local/bin || fatal "Failed to install helm to /usr/local/bin"

  echo "------------------------------------------------------------------------------------"
  echo -e "  Run: $BLUE 'source ~/.bashrc' "$NO_COLOR
  echo "  Run on the worker nodes"
  echo -e "  - '$BLUE curl -sfL http://$serverIp:8080/$0 | bash -s -- worker $serverIp $NO_COLOR'"
  echo "------------------------------------------------------------------------------------"

}

################################# deploy worker ################################
function deploy_worker () {
  echo - deploy worker

  # base bits
  base

  # add repo 
cat << EOF > /etc/yum.repos.d/hauler.repo
[hauler]
name=Hauler Air Gap Server
baseurl=http://$serverIp:8080
enabled=1
gpgcheck=0
EOF

  # clean all the yums
  yum clean all  > /dev/null 2>&1

  # setup RKE2
  mkdir -p /etc/rancher/rke2/
  echo -e "server: https://$serverIp:9345\ntoken: bootstrapAllTheThings\nwrite-kubeconfig-mode: 0600\n#profile: cis-1.23\nkube-apiserver-arg:\n- \"authorization-mode=RBAC,Node\"\nkubelet-arg:\n- \"protect-kernel-defaults=true\" " > /etc/rancher/rke2/config.yaml
  
  # set registry override
  echo -e "mirrors:\n  docker.io:\n    endpoint:\n      - http://$serverIp:5000\n  \"$serverIp:5000\":\n    endpoint:\n      - http://$serverIp:5000" > /etc/rancher/rke2/registries.yaml

  # install rke2
  yum install -y rke2-agent rke2-common rke2-selinux > /dev/null 2>&1
  systemctl enable --now rke2-agent.service > /dev/null 2>&1
  info "worker node running"
}

################################# flask ################################
function flask () {
  # dummy 3 tier app - asked for by a customer. 
 info "deploy flask app"
 curl -sfL http://$serverIp:8080/flask.yaml | sed -e s/localhost/$serverIp/g -e s/XXX/$DOMAIN/g | kubeectl apply -f -  
}

################################# longhorn ################################
function longhorn () {
  # deploy longhorn with local helm/images
  info "deploying longhorn"
    helm upgrade -i longhorn oci://$serverIp:5000/hauler/longhorn --namespace longhorn-system --create-namespace --set ingress.enabled=true --set ingress.host=longhorn.$DOMAIN --set global.cattle.systemDefaultRegistry=$serverIp:5000 --plain-http
}

################################# neuvector ################################
function neuvector () {
  # deploy neuvector with local helm/images
  info "deploying neuvector"
  helm upgrade -i neuvector --namespace neuvector oci://$serverIp:5000/hauler/core --create-namespace  --set k3s.enabled=true --set k3s.runtimePath=/run/k3s/containerd/containerd.sock  --set manager.ingress.enabled=true --set controller.pvc.enabled=true --set manager.svc.type=ClusterIP --set controller.pvc.capacity=500Mi --set registry=http://$serverIp:5000 --set controller.image.repository=neuvector/controller --set enforcer.image.repository=neuvector/enforcer --set manager.image.repository=neuvector/manager --set cve.updater.image.repository=neuvector/updater --set manager.ingress.host=neuvector.$DOMAIN --set internal.certmanager.enabled=true --plain-http
}

################################# rancher ################################
function rancher () {
  # deploy rancher with local helm/images
  info "deploying cert-manager"
  helm upgrade -i cert-manager oci://$serverIp:5000/hauler/cert-manager --version $(curl -sfL http://$serverIp:8080/_hauler_index.txt | grep hauler/cert | awk '{print $2}'| awk -F: '{print $2}') --namespace cert-manager --create-namespace --set installCRDs=true --set image.repository=$serverIp:5000/jetstack/cert-manager-controller --set webhook.image.repository=$serverIp:5000/jetstack/cert-manager-webhook --set cainjector.image.repository=$serverIp:5000/jetstack/cert-manager-cainjector --set startupapicheck.image.repository=$serverIp:5000/jetstack/cert-manager-startupapicheck --plain-http

  info "deploying rancher"
  helm upgrade -i rancher oci://$serverIp:5000/hauler/rancher --namespace cattle-system --create-namespace --set bootstrapPassword=bootStrapAllTheThings --set replicas=1 --set auditLog.level=2 --set auditLog.destination=hostPath --set useBundledSystemChart=true --set rancherImage=$serverIp:5000/rancher/rancher --set systemDefaultRegistry=$serverIp:5000 --set hostname=rancher.$DOMAIN --plain-http

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
  echo " $0 flask # deploy a 3 tier app"
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
  echo -e "   - On 1st node run:"
  echo -e "     -$BLUE mkdir /opt/hauler && tar -I zstd -vxf hauler_airgap_$(date '+%m_%d_%y').zst -C /opt/hauler"$NO_COLOR
  echo -e "     -$BLUE cd /opt/hauler; $0 control"$NO_COLOR
  echo ""
  echo -e "   - On 2nd, and 3rd nodes run:"
  echo -e "      -$BLUE curl -sfL http://$serverIp:8080/hauler_all_the_things.sh | bash -s -- worker $serverIp "$NO_COLOR
  echo ""
  echo " - Application Setup from 1st node install"
  echo -e "   - Longhorn : $0$BLUE longhorn"$NO_COLOR
  echo -e "   - Rancher : $0$BLUE rancher"$NO_COLOR
  echo -e "   - NeuVector : $0$BLUE neuvector"$NO_COLOR
  echo -e "   - Flask : $0$BLUE flask"$NO_COLOR
  echo ""
  echo "-------------------------------------------------"
  echo ""
  exit 1
}

case "$1" in
        build ) build;;
        control) deploy_control;;
        worker) deploy_worker;;
        neuvector) neuvector;;
        longhorn) longhorn;;
        rancher) rancher;;
        flask) flask;;
        validate) validate;;
        *) usage;;
esac