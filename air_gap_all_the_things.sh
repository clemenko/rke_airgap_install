#!/bin/bash

set -ebpf

export RKE_VERSION=v1.24.6
export CERT_VERSION=v1.8.0
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

  mkdir -p /opt/rke2_$RKE_VERSION/
  cd /opt/rke2_$RKE_VERSION/

  echo - download rke, rancher and longhorn
  curl -#OL https://github.com/rancher/rke2/releases/download/$RKE_VERSION%2Brke2r2/rke2-images.linux-amd64.tar.zst
  curl -#OL https://github.com/rancher/rke2/releases/download/$RKE_VERSION%2Brke2r2/rke2.linux-amd64.tar.gz
  curl -#OL https://github.com/rancher/rke2/releases/download/$RKE_VERSION%2Brke2r2/sha256sum-amd64.txt
  curl -#OL https://rpm.rancher.io/rke2/latest/common/centos/8/noarch/rke2-selinux-0.9-1.el8.noarch.rpm
  curl -#OL https://rpm.rancher.io/rke2/latest/1.24/centos/8/x86_64/rke2-common-1.24.3~rke2r1-0.el8.x86_64.rpm

  echo - get the install script
  curl -sfL https://get.rke2.io -o install.sh

  echo - Get Helm Charts

  echo - create helm dir
  mkdir -p /opt/helm/
  cd /opt/helm/

  echo - get helm
  curl -#L https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

  echo - add repos
  helm repo add jetstack https://charts.jetstack.io
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
  helm repo add longhorn https://charts.longhorn.io
  helm repo update

  echo - get charts
  helm pull jetstack/cert-manager --version $CERT_VERSION
  helm pull rancher-latest/rancher
  helm pull longhorn/longhorn

  echo - Get Images - Rancher/Longhorn

  echo - create image dir
  mkdir -p /opt/images/{cert,rancher,longhorn}
  cd /opt/images/

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
  helm template /opt/helm/cert-manager-$CERT_VERSION.tgz | awk '$1 ~ /image:/ {print $2}' | sed s/\"//g > cert/cert-manager-images.txt

  echo - longhorn image list
  curl -#L https://raw.githubusercontent.com/longhorn/longhorn/$LONGHORN_VERSION/deploy/longhorn-images.txt -o longhorn/longhorn-images.txt

  echo - skopeo cert-manager
  for i in $(cat cert/cert-manager-images.txt); do 
    skopeo copy docker://$i docker-archive:cert/$(echo $i| awk -F/ '{print $3}'|sed 's/:/_/g').tar:$(echo $i| awk -F/ '{print $3}') 
  done

  echo - skopeo - longhorn
  for i in $(cat longhorn/longhorn-images.txt); do 
    skopeo copy docker://$i docker-archive:longhorn/$(echo $i| awk -F/ '{print $2}'|sed 's/:/_/g').tar:$(echo $i| awk -F/ '{print $2}') 
  done

  echo - skopeo - Rancher - This will take time getting all the images
  for i in $(cat rancher/rancher-images.txt); do 
    skopeo copy docker://$i docker-archive:rancher/$(echo $i| awk -F/ '{print $2}'|sed 's/:/_/g').tar:$(echo $i| awk -F/ '{print $2}')
  done

  mv rancher/busybox.tar rancher/busybox_latest.tar

  echo - Get Nerdctl
  mkdir -p /opt/nerdctl/
  cd /opt/nerdctl/
  curl -#LO https://github.com/containerd/nerdctl/releases/download/v0.18.0/nerdctl-0.18.0-linux-amd64.tar.gz

  cd /opt
  echo - compress all the things
  tar -I zstd -vcf /opt/rke2_rancher_longhorn.zst $(ls)

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
  echo -e "#disable: rke2-ingress-nginx\n#profile: cis-1.6\nselinux: false" > /etc/rancher/rke2/config.yaml

  INSTALL_RKE2_ARTIFACT_PATH=/opt/rancher/rke2_$RKE_VERSION sh /opt/rancher/rke2_$RKE_VERSION/install.sh 
  systemctl enable rke2-server.service && systemctl start rke2-server.service

  # get node token
  rsync -avP /var/lib/rancher/rke2/server/token /opt/rancher/node-token

  # wait and add link
  export KUBECONFIG=/etc/rancher/rke2/rke2.yaml 
  ln -s /var/lib/rancher/rke2/data/v1*/bin/kubectl  /usr/local/bin/kubectl 

  echo - Setup nerdctl
  tar -zxvf /opt/rancher/nerdctl/nerdctl-0.18.0-linux-amd64.tar.gz -C /opt/rancher/nerdctl 
  mv /opt/rancher/nerdctl/nerdctl /usr/local/bin
  ln -s /run/k3s/containerd/containerd.sock /run/containerd/containerd.sock

  echo - Setup nfs
  # share out opt directory
  echo "/opt/rancher  0.0.0.0/24(ro)" > /etc/exports
  systemctl enable nfs-server.service && systemctl start nfs-server.service

  echo - run local registry
  # Adam made me use localhost:5000
  mkdir /opt/rancher/registry
  nerdctl load -i /opt/rancher/images/rancher/registry_2.tar 
  nerdctl run -d -v /opt/rancher/registry:/var/lib/registry -p 5000:5000 --restart always --name registry registry:2

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

