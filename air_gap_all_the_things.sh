#!/bin/bash

set -ebpf

export RKE_VERSION=1.24.7
export CERT_VERSION=v1.10.0
export RANCHER_VERSION=v2.6.8
export LONGHORN_VERSION=v1.3.1

######  NO MOAR EDITS #######
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
NORMAL=$(tput sgr0)
BLUE=$(tput setaf 4)

#better error checking
#command -v skopeo >/dev/null 2>&1 || { echo "$RED" " ** skopeo was not found. Please install. ** " "$NORMAL" >&2; exit 1; }

################################# build ################################
function build () {

  echo - Installing packages
  yum install zstd skopeo -y

  mkdir -p /opt/rancher/rke2_$RKE_VERSION/
  cd /opt/rancher/rke2_$RKE_VERSION/

  echo - download rke, rancher and longhorn
  curl -#OL https://github.com/rancher/rke2/releases/download/v$RKE_VERSION%2Brke2r1/rke2-images.linux-amd64.tar.zst
  curl -#OL https://github.com/rancher/rke2/releases/download/v$RKE_VERSION%2Brke2r1/rke2.linux-amd64.tar.gz
  curl -#OL https://github.com/rancher/rke2/releases/download/v$RKE_VERSION%2Brke2r1/sha256sum-amd64.txt
  curl -#OL https://github.com/rancher/rke2-packaging/releases/download/v$RKE_VERSION%2Brke2r1.stable.0/rke2-common-$RKE_VERSION.rke2r1-0.x86_64.rpm
  curl -#OL https://github.com/rancher/rke2-selinux/releases/download/v0.9.stable.1/rke2-selinux-0.9-1.el8.noarch.rpm

  echo - get the install script
  curl -sfL https://get.rke2.io -o install.sh

  echo - Get Helm Charts
  mkdir -p /opt/rancher/helm/
  cd /opt/rancher/helm/

  echo - get helm
  curl -#L https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash > /dev/null 2>&1

  echo - add repos
  helm repo add jetstack https://charts.jetstack.io > /dev/null 2>&1
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest > /dev/null 2>&1
  helm repo add longhorn https://charts.longhorn.io > /dev/null 2>&1
  helm repo update > /dev/null 2>&1

  echo - get charts
  helm pull jetstack/cert-manager --version $CERT_VERSION > /dev/null 2>&1
  helm pull rancher-latest/rancher > /dev/null 2>&1
  helm pull longhorn/longhorn > /dev/null 2>&1

  echo - Get Images - Rancher/Longhorn

  echo - create image dir
  mkdir -p /opt/rancher/images/{cert,rancher,longhorn}
  cd /opt/rancher/images/

  echo - rancher image list 
  curl -#L https://github.com/rancher/rancher/releases/download/$RANCHER_VERSION/rancher-images.txt -o rancher/orig_rancher-images.txt

  echo - shorten rancher list with a sort
  # fix library tags
  sed -i -e '0,/busybox/s/busybox/library\/busybox/' -e 's/registry/library\/registry/g' rancher/orig_rancher-images.txt
  
  # remove things that are not needed and overlapped
  sed -i -E '/neuvector|minio|gke|aks|eks|sriov|harvester|mirrored|longhorn|thanos|tekton|istio|multus|hyper|jenkins|windows/d' rancher/orig_rancher-images.txt

  # get latest version
  for i in $(cat rancher/orig_rancher-images.txt|awk -F: '{print $1}'); do 
    grep -w $i rancher/orig_rancher-images.txt | sort -Vr| head -1 >> rancher/version_unsorted.txt
  done
 
  # final sort
  cat rancher/version_unsorted.txt | sort -u >> rancher/rancher-images.txt

  echo - We need to add the cert-manager images
  helm template /opt/rancher/helm/cert-manager-$CERT_VERSION.tgz | awk '$1 ~ /image:/ {print $2}' | sed s/\"//g > cert/cert-manager-images.txt

  echo - longhorn image list
  curl -#L https://raw.githubusercontent.com/longhorn/longhorn/$LONGHORN_VERSION/deploy/longhorn-images.txt -o longhorn/longhorn-images.txt

  echo - skopeo - cert-manager
  for i in $(cat cert/cert-manager-images.txt); do 
    skopeo copy docker://$i docker-archive:cert/$(echo $i| awk -F/ '{print $3}'|sed 's/:/_/g').tar:$(echo $i| awk -F/ '{print $3}') > /dev/null 2>&1
  done

  echo - skopeo - longhorn
  for i in $(cat longhorn/longhorn-images.txt); do 
    skopeo copy docker://$i docker-archive:longhorn/$(echo $i| awk -F/ '{print $2}'|sed 's/:/_/g').tar:$(echo $i| awk -F/ '{print $2}') > /dev/null 2>&1
  done

  echo - skopeo - Rancher - be patient...
  for i in $(cat rancher/rancher-images.txt); do 
    skopeo copy docker://$i docker-archive:rancher/$(echo $i| awk -F/ '{print $2}'|sed 's/:/_/g').tar:$(echo $i| awk -F/ '{print $2}') > /dev/null 2>&1
  done

  mv rancher/busybox.tar rancher/busybox_latest.tar

  echo - Get Nerdctl
  mkdir -p /opt/rancher/nerdctl/
  cd /opt/rancher/nerdctl/
  curl -#LO https://github.com/containerd/nerdctl/releases/download/v1.0.0/nerdctl-1.0.0-linux-amd64.tar.gz

  cd /opt/rancher/
  echo - compress all the things
  tar -I zstd -vcf /opt/rke2_rancher_longhorn.zst $(ls) > /dev/null 2>&1


  # look at adding encryption - https://medium.com/@lumjjb/encrypting-container-images-with-skopeo-f733afb1aed4
  
}

################################# deploy ################################
function deploy () {
  # this is for the first node
  echo Untar the bits
  mkdir /opt/rancher
  yum install zstd nfs-utils iptables skopeo -y
  tar -I zstd -vxf rke2_rancher_longhorn.zst -C /opt/rancher

  echo Install rke2
  useradd -r -c "etcd user" -s /sbin/nologin -M etcd -U
  mkdir -p /etc/rancher/rke2/ /var/lib/rancher/rke2/server/manifests/
  echo -e "#profile: cis-1.6\nselinux: true\nsecrets-encryption: true\nwrite-kubeconfig-mode: 0640\nstreaming-connection-idle-timeout: 5m\nkube-controller-manager-arg:\n- bind-address=127.0.0.1\n- use-service-account-credentials=true\n- tls-min-version=VersionTLS12\n- tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384\nkube-scheduler-arg:\n- tls-min-version=VersionTLS12\n- tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384\nkube-apiserver-arg:\n- tls-min-version=VersionTLS12\n- tls-cipher-suites=TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384\n- authorization-mode=RBAC,Node\n- anonymous-auth=false\n- audit-policy-file=/etc/rancher/rke2/audit-policy.yaml\n- audit-log-mode=blocking-strict\n- audit-log-maxage=30\nkubelet-arg:\n- protect-kernel-defaults=true\n- read-only-port=0\n- authorization-mode=Webhook" > /etc/rancher/rke2/config.yaml

  # set up audit policy file
  echo -e "apiVersion: audit.k8s.io/v1\nkind: Policy\nrules:\n- level: RequestResponse" > /etc/rancher/rke2/audit-policy.yaml

  # set up ssl passthrough for nginx
  echo -e "---\napiVersion: helm.cattle.io/v1\nkind: HelmChartConfig\nmetadata:\n  name: rke2-ingress-nginx\n  namespace: kube-system\nspec:\n  valuesContent: |-\n    controller:\n      config:\n        use-forwarded-headers: true\n      extraArgs:\n        enable-ssl-passthrough: true" > /var/lib/rancher/rke2/server/manifests/rke2-ingress-nginx-config.yaml; 

  INSTALL_RKE2_ARTIFACT_PATH=/opt/rancher/rke2_$RKE_VERSION sh /opt/rancher/rke2_$RKE_VERSION/install.sh 
  yum install -y /opt/rke2_1.24.7/rke2*.rpm
  systemctl enable rke2-server.service && systemctl start rke2-server.service

  # get node token
  # rsync -avP /var/lib/rancher/rke2/server/token /opt/rancher/node-token

  # wait and add link
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml 
  ln -s /var/lib/rancher/rke2/data/v1*/bin/kubectl  /usr/local/bin/kubectl 

  # /var/lib/rancher/rke2/agent/images/

  echo - Setup nerdctl
  tar -zxvf /opt/rancher/nerdctl/nerdctl-1.0.0-linux-amd64.tar.gz -C /opt/rancher/nerdctl 
  mv /opt/rancher/nerdctl/nerdctl /usr/local/bin
  ln -s /run/k3s/containerd/containerd.sock /run/containerd/containerd.sock

  echo - Setup nfs
  # share out opt directory
  echo "/opt/rancher  0.0.0.0/24(ro)" > /etc/exports
  systemctl enable nfs-server.service && systemctl start nfs-server.service

  echo - run local registry
  # Adam made me use localhost:5000
  mkdir /opt/rancher/registry

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: registry
  labels:
    app: registry
spec:
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
      - name: registry
        image: registry:2
        ports:
        - name: registry
          containerPort: 5000
        securityContext:
          capabilities:
            add:
            - NET_BIND_SERVICE
    hostNetwork: true
EOF

#  nerdctl load -i /opt/rancher/images/rancher/registry_2.tar 
#  nerdctl run -d -v /opt/rancher/registry:/var/lib/registry -p 5000:5000 --restart always --name registry registry:2

  echo - load images
  for file in $(ls /opt/rancher/images/longhorn/ | grep -v txt ); do 
    skopeo copy docker-archive:/opt/rancher/images/longhorn/$file docker://$(echo $file | sed 's/.tar//g' | awk -F_ '{print "localhost:5000/"$1":"$2}') --dest-tls-verify=false
  done

  for file in $(ls /opt/rancher/images/cert/ | grep -v txt ); do 
    skopeo copy docker-archive:/opt/rancher/images/cert/$file docker://$(echo $file | sed 's/.tar//g' | awk -F_ '{print "localhost:5000/"$1":"$2}') --dest-tls-verify=false
  done

  for file in $(ls /opt/rancher/images/rancher/ | grep -v txt ); do 
    skopeo copy docker-archive:/opt/rancher/images/rancher/$file docker://$(echo $file | sed 's/.tar//g' | awk -F_ '{print "localhost:5000/"$1":"$2}') --dest-tls-verify=false
  done

  # deploy rancher : https://rancher.com/docs/rancher/v2.6/en/installation/other-installation-methods/air-gap/install-rancher/
  
}

############################# usage ################################
function usage () {
  echo ""
  echo "-------------------------------------------------"
  echo ""
  echo " Usage: $0 {build | deploy}"
  echo ""
  echo " ./k3s.sh build # download and create the monster TAR "
  echo " ./k3s.sh deploy # unpack and deploy"
  echo ""
  echo "-------------------------------------------------"
  echo ""
  exit 1
}

case "$1" in
        build ) build;;
        deploy) deploy;;
        *) usage;;
esac

