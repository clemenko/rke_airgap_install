---
title: How to Air Gap RKE2, Longhorn, and Rancher
author: Andy Clemenko, @clemenko, andy.clemenko@rancherfederal.com
---

# How to Air Gap RKE2, Longhorn, and Rancher

![logp](img/logo_long.jpg)

This guide is very similar to [Simple RKE2, Longhorn, and Rancher Install ](https://github.com/clemenko/rke_install_blog), except in one major way. This guide will provide a strategy for air gapping all the bits needed for RKE2, Longhorn and Rancher. This is just one opinion. We are starting from the idea that there is no container infrastructure available.

Throughout my career there has always been a disconnect between the documentation and the practical implementation. The Kubernetes (k8s) ecosystem is no stranger to this problem. This guide is a simple approach to installing Kubernetes and some REALLY useful tools. We will walk through installing all the following.

- [RKE2](https://docs.rke2.io) - Security focused Kubernetes
- [Rancher](https://www.suse.com/products/suse-rancher/) - Multi-Cluster Kubernetes Management
- [Longhorn](https://longhorn.io) - Unified storage layer

We will need a few tools for this guide. Hopefully everything at handled by my [air_gap_all_the_things.sh](https://github.com/clemenko/rke_airgap_install/blob/main/air_gap_all_the_things.sh) script. For this guide all the commands will be in the script.

---

> **Table of Contents**:
>
> * [Whoami](#whoami)
> * [Prerequisites](#prerequisites)
> * [Build](#Build)
> * [Deploy Control Plane](#Deploy_Control_Plane)
> * [Deploy Workers](#Deploy_Workers)
> * [Conclusion](#conclusion)

---

## Whoami

Just a geek - Andy Clemenko - @clemenko - andy.clemenko@rancherfederal.com

## Prerequisites

The prerequisites are fairly simple. We need 3 Linux servers ( airgap1, airgap2, airgap3 ) with one of the servers having access to the internet. To be fair we are going to use the internet to get the bits. The servers can be bare metal, or in the cloud provider of your choice. I prefer [Digital Ocean](https://digitalocean.com). For the video I am going to use [Harvester](https://www.rancher.com/products/harvester) running on a 1u server. We will need an `ssh` client to connect to the servers. DNS is a great to have but not necessary.

## Build

Because we are moving bits across an air gap we need a server with access to the internet. Let's ssh into `airgap1` to start the download/build process. There are a few tools we will need like [Skopeo](https://github.com/containers/skopeo) and [Helm](https://helm.sh/). We will walk through getting everything needed. We will need root for all three servers. The following instructions are going to be high level. The script [air_gap_all_the_things.sh](https://github.com/clemenko/rke_airgap_install/blob/main/air_gap_all_the_things.sh) will take care of almost everything.

### Install Skopeo

Skopeo is a great tool to inspect and interact with registries. We can use it to download the images in a clean manor. The bonus part is that we do not need a container runtime active.

### Get Tarballs - RKE2

For getting all the RKE2 files we can follow the docs at [https://docs.rke2.io/install/airgap](https://docs.rke2.io/install/airgap). There are two ways to install RKE2, RPM and the Tarball. I have found the tarball to be a little easier for air gaps. Especially if Ubuntu is potentially involved. All the files we need are being hosting on the [rke github](https://github.com/rancher/rke2/). The files that are needed are as follows :

```bash
export RKE_VERSION=1.24.8
  # images
  curl -#OL https://github.com/rancher/rke2/releases/download/v$RKE_VERSION%2Brke2r1/rke2-images.linux-amd64.tar.zst
  # binaries
  curl -#OL https://github.com/rancher/rke2/releases/download/v$RKE_VERSION%2Brke2r1/rke2.linux-amd64.tar.gz
  # Sha
  curl -#OL https://github.com/rancher/rke2/releases/download/v$RKE_VERSION%2Brke2r1/sha256sum-amd64.txt
  # selinux and common rpm
  curl -#OL https://github.com/rancher/rke2-packaging/releases/download/v$RKE_VERSION%2Brke2r1.stable.0/rke2-common-$RKE_VERSION.rke2r1-0.x86_64.rpm
  curl -#OL https://github.com/rancher/rke2-selinux/releases/download/v0.9.stable.1/rke2-selinux-0.9-1.el8.noarch.rpm
```

Along with the Tars we will need the tarball install script.

```bash
 curl -sfL https://get.rke2.io -o install.sh
 ```

### Get Helm Charts

The good news about Helm is that all the charts are easy to get. However we will need to have helm installed on the build node. Helm is easy enough to install.

```bash
  curl -#L https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

We will also need to use Helm on deploy process. So it might be worth while to get the Helm tar.

```bash
  curl -#LO https://get.helm.sh/helm-v3.10.2-linux-386.tar.gz 
```

With Helm installed we can add the repos and "pull" the charts. We will need the charts for Cert-Manager, Rancher and Longhorn.

```bash
export CERT_VERSION=v1.10.0
export RANCHER_VERSION=v2.7.0
export LONGHORN_VERSION=v1.3.2

  helm repo add jetstack https://charts.jetstack.io 
  helm repo add rancher-latest https://releases.rancher.com/server-charts/latest 
  helm repo add longhorn https://charts.longhorn.io 
  helm repo update 

  helm pull jetstack/cert-manager --version $CERT_VERSION 
  helm pull rancher-latest/rancher --version $RANCHER_VERSION 
  helm pull longhorn/longhorn --version $LONGHORN_VERSION 
```

### Get Images - Rancher & Longhorn

For getting the images we need to start with the image lists. There are two ways to get the image list. Either from the chart itself or from a published list. For Cert-Manager we can used the chart.

```bash
helm template /opt/rancher/helm/cert-manager-$CERT_VERSION.tgz | awk '$1 ~ /image:/ {print $2}' | sed s/\"//g > cert-manager-images.txt
```

For Rancher and Longhorn we need to pull the published list. For Rancher the list may include older versions that are not needed for a greenfield install. The script at the end of this guide cleans up the list for just the current versions.

```bash
# Rancher
  curl -#L https://github.com/rancher/rancher/releases/download/$RANCHER_VERSION/rancher-images.txt -o rancher-images.txt

# Longhorn
  curl -#L https://raw.githubusercontent.com/longhorn/longhorn/$LONGHORN_VERSION/deploy/longhorn-images.txt longhorn-images.txt
```

Now that we have the image lists we can use [skopeo](https://github.com/containers/skopeo) to pull the images and save them locally. Here is an example of a for-do loop. The script will step through the list, pull the image, and then save it locally as a tar.

```bash
  echo - skopeo - cert-manager
  for i in $(cat cert-manager-images.txt); do 
    skopeo copy docker://$i docker-archive:$(echo $i| awk -F/ '{print $3}'|sed 's/:/_/g').tar:$(echo $i| awk -F/ '{print $3}') > /dev/null 2>&1
  done
```

This process will need to be repeated for Longhorn, Rancher, and Cert-Manager.

We will need to get one more image. We need the [Docker Registry](https://hub.docker.com/_/registry) for serving the images out internally.

```bash
curl -#L https://github.com/clemenko/rke_airgap_install/raw/main/registry.tar -o registry_2.tar
```

### Package and Move all the bits

Hopefully we have everything organized that we can `tar` up all the files. The ZST compression seems to be the best right now. 

```bash
tar -I zstd -vcf /opt/rke2_rancher_longhorn.zst *
```

## Move the tar

At the time of writing this guide the compressed zst is 5.3G. 

## Deploy Control Plane

### Uncompress

### First Control Plane Node

## Deploy Workers

### Mount First Node

## The SCRIPT

### Get the Script

We are going to use `curl` to get the script from Github. Keep in mind that the script is always being updated. Again this in the first node that has access to the internet.

```bash
mkdir /opt/rancher
cd /opt/rancher
curl -#OL https://raw.githubusercontent.com/clemenko/rke_airgap_install/main/air_gap_all_the_things.sh
chmod 755 air_gap_all_the_things.sh
```

### Check the Versions

Edit `air_gap_all_the_things.sh` and validate the versions are correct. 

### Run the Build

Note: The `./air_gap_all_the_things.sh build` is only needed to get all the bits and create the tar.zst that needs to be air gapped. Please be patient as it is pulling 15Gb from the interwebs.

```bash
./air_gap_all_the_things.sh build
```

The result will be all the files under `/opt/rancher/` and the tar that needs to be moved `/opt/rke2_rancher_longhorn.zst`.

## Conclusion

![success](img/success.jpg)
