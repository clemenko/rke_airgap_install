#!/bin/bash

# docs https://rancherfederal.github.io/hauler-docs/docs/introduction/quickstart#using-a-hauler-manifest

# mkdir /opt/hauler && cd /opt/hauler && curl -#OL https://raw.githubusercontent.com/clemenko/rke_airgap_install/main/make_hauler.sh && chmod 755 make_hauler.sh 

set -ebpf

export RED='\x1b[0;31m'
export GREEN='\x1b[32m'
export BLUE='\x1b[34m'
export YELLOW='\x1b[33m'
export NO_COLOR='\x1b[0m'

# el version
# set to el8 or el9
export EL=$(rpm -q --queryformat '%{RELEASE}' rpm | grep -o "el[[:digit:]]")

# check for root
#if [ $(whoami) != "root" ] ; then echo -e "$RED" " ** please run $0 as root ** " "$NO_COLOR"; exit; fi

# get helm if needed
echo -e "checking helm "
command -v helm >/dev/null 2>&1 || { echo -e -n "$RED" " ** helm was not found ** ""$NO_COLOR"; curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash  > /dev/null 2>&1; }

# get hauler if needed
echo -e "checking hauler "
command -v hauler >/dev/null 2>&1 || { echo -e -n "$RED" " ** hauler was not found ** ""$NO_COLOR"; curl -sfL https://get.hauler.dev | bash  > /dev/null 2>&1; }

# get jq if needed
echo -e "checking jq "
command -v jq >/dev/null 2>&1 || { echo -e -n "$RED" " ** jq was not found ** ""$NO_COLOR"; yum install epel-release -y  > /dev/null 2>&1; yum install -y jq > /dev/null 2>&1; }
echo -e "- installed ""$GREEN""ok" "$NO_COLOR"

echo -e "creating hauler manifest"
echo -e -n " - adding images "

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
EOF

for i in $(helm template jetstack/cert-manager --version $CERT_VERSION | awk '$1 ~ /image:/ {print $2}' | sed 's/\"//g'); do echo "    - name: "$i >> airgap_hauler.yaml; done
for i in $(helm template neuvector/core --version $NEU_VERSION | awk '$1 ~ /image:/ {print $2}' | sed -e 's/\"//g'); do echo "    - name: "$i >> airgap_hauler.yaml; done
for i in $(curl -sL https://raw.githubusercontent.com/longhorn/longhorn/$LONGHORN_VERSION/deploy/longhorn-images.txt); do echo "    - name: "$i >> airgap_hauler.yaml; done


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

for i in $(cat hauler_temp/rancher-images.txt); do echo "    - name: "$i >> airgap_hauler.yaml; done

rm -rf hauler_temp

echo -e "$GREEN""ok" "$NO_COLOR"

# charts &  files
echo -e -n " - adding charts and files "

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
    - path: https://get.rke2.io
      name: install.sh
    - path: https://github.com/rancher/rke2/releases/download/v$RKE_VERSION%2Brke2r1/rke2-images.linux-amd64.tar.zst
    - path: https://github.com/rancher/rke2/releases/download/v$RKE_VERSION%2Brke2r1/rke2.linux-amd64.tar.gz
    - path: https://github.com/rancher/rke2/releases/download/v$RKE_VERSION%2Brke2r1/sha256sum-amd64.txt
    - path: https://github.com/rancher/rke2-packaging/releases/download/v$RKE_VERSION%2Brke2r1.stable.0/rke2-common-$RKE_VERSION.rke2r1-0.$EL.x86_64.rpm
    - path: https://github.com/rancher/rke2-selinux/releases/download/v0.17.stable.1/rke2-selinux-0.17-1.$EL.noarch.rpm
    - path: https://get.helm.sh/helm-$(curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r .tag_name)-linux-amd64.tar.gz
EOF

echo -e "$GREEN""ok" "$NO_COLOR"

# https://rancherfederal.github.io/hauler-docs/docs/introduction/quickstart#using-a-hauler-manifest


echo "-------------------------------------------------------------------------------------------"
echo " hauler store and save: "
echo " "
echo -e " -$BLUE hauler store sync -f airgap_hauler.yaml$NO_COLOR"
echo -e " -$BLUE hauler store save$NO_COLOR"
echo " "
echo " hauler docs: https://rancherfederal.github.io/hauler-docs/ "
echo " hauler repo: https://github.com/rancherfederal/hauler "
echo "-------------------------------------------------------------------------------------------"
