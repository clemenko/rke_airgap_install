---
title: Simple RKE2, Longhorn, and Rancher Install - AIR GAPPED
author: Andy Clemenko, @clemenko, andy.clemenko@rancherfederal.com
---

# Simple RKE2, Longhorn, and Rancher Install - AIR GAPPED

![logp](img/logo_long.jpg)

This guide is very similar to [Simple RKE2, Longhorn, and Rancher Install ](https://github.com/clemenko/rke_install_blog), except in one major way. This guide will lay everything out for an air gapped install.

Throughout my career there has always been a disconnect between the documentation and the practical implementation. The Kubernetes (k8s) ecosystem is no stranger to this problem. This guide is a simple approach to installing Kubernetes and some REALLY useful tools. We will walk through installing all the following.

- [RKE2](https://docs.rke2.io) - Security focused Kubernetes
- [Rancher](https://www.suse.com/products/suse-rancher/) - Multi-Cluster Kubernetes Management
- [Longhorn](https://longhorn.io) - Unified storage layer

We will need a few tools for this guide. We will walk through how to install `helm` and `kubectl`.

---

> **Table of Contents**:
>
> * [Whoami](#whoami)
> * [Prerequisites](#prerequisites)
> * [Linux Servers](#linux-servers)
> * [RKE2 Install](#rke2-install)
>   * [RKE2 Server Install](#rke2-server-install)
>   * [RKE2 Agent Install](#rke2-agent-install)
> * [Rancher](#rancher)
>   * [Rancher Install](#rancher-install)
>   * [Rancher Gui](#rancher-gui)
> * [Longhorn](#longhorn)
>   * [Longhorn Install](#longhorn-install)
>   * [Longhorn Gui](#longhorn-gui)
> * [Automation](#automation)
> * [Conclusion](#conclusion)

---

## Whoami

Just a geek - Andy Clemenko - @clemenko - andy.clemenko@rancherfederal.com

## Prerequisites

The prerequisites are fairly simple. We need 4 Rocky Linux servers with one of the servers having access to the internet. To be fair we are going to use the internet to get the bits. They can be bare metal, or in the cloud provider of your choice. I prefer [Digital Ocean](https://digitalocean.com). We need an `ssh` client to connect to the servers. And finally DNS to make things simple. Ideally we need a URL for the Rancher interface. For the purpose of the this guide let's use `rancher.dockr.life`. We will need to point that name to the first server of the cluster. While we are at it, a wildcard DNS for your domain will help as well.

## Migration Server

Because we are moving bit across an air gap we need a server on the internet. Because I am using a cloud provider I am going to spin a 4th Rocky Linux server name `rancher4`. Most of the challenge of air gaps is getting all the bits. Don't ask me how I know. Let's ssh into `rancher4` to start the downloading process. Since we are connected to the internet we can install a few tools like [Skopeo](https://github.com/containers/skopeo). Once we have all the tars, and images we will run a docker registry for installing Rancher and Longhorn. We are going to assume root access since this is a throw away server.

### Install Skopeo

Skopeo is a great tool to inspect and interact with registries. We can use it to download the images in a clean manor.

```bash
dnf -y install skopeo
```

### Get Tars - RKE2

```bash
# create install directory
mkdir /root/rke2/
cd /root/rke2/

# download rke, rancher and longhorn
curl -#OL https://github.com/rancher/rke2/releases/download/v1.23.4%2Brke2r2/rke2-images.linux-amd64.tar.zst
curl -#OL https://github.com/rancher/rke2/releases/download/v1.23.4%2Brke2r2/rke2.linux-amd64.tar.gz
curl -#OL https://github.com/rancher/rke2/releases/download/v1.23.4%2Brke2r2/sha256sum-amd64.txt

# get the install script
curl -sfL https://get.rke2.io --output install.sh
```

### Get Helm Charts

```bash
# create helm dir
mkdir /root/helm/
cd /root/helm/

# get helm
curl -#L https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# add repos
helm repo add jetstack https://charts.jetstack.io
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo add longhorn https://charts.longhorn.io
helm repo update

# get charts
helm pull jetstack/cert-manager
helm pull rancher-latest/rancher
helm pull longhorn/longhorn

# get the cert-manager crt
curl -#LO https://github.com/jetstack/cert-manager/releases/download/v1.7.2/cert-manager.crds.yaml
```

### Get Images - Rancher & Longhorn

**Please be patient. Downloading images will take some time!**

```bash
# create image dir
mkdir -p /root/images/{cert,rancher,longhorn}
cd /root/images/

# rancher image list 
curl -#L https://github.com/rancher/rancher/releases/download/v2.6.4/rancher-images.txt -o ./rancher/orig_rancher-images.txt

# shorten rancher list with a sort
sed -i -e '0,/busybox/s/busybox/library\/busybox/' -e 's/registry/library\/registry/g' rancher/orig_rancher-images.txt
for i in $(cat rancher/orig_rancher-images.txt|awk -F: '{print $1}'); do 
  grep -w $i rancher/orig_rancher-images.txt | sort -Vr| head -1 >> rancher/version_unsorted.txt
done
grep -x library/busybox rancher/orig_rancher-images.txt | sort -Vr| head -1 > rancher/rancher-images.txt
cat rancher/version_unsorted.txt | sort -u >> rancher/rancher-images.txt

# We need to add the cert-manager images
helm template /root/helm/cert-manager-*.tgz | awk '$1 ~ /image:/ {print $2}' | sed s/\"//g > ./cert/cert-manager-images.txt

# longhorn image list
curl -#L https://raw.githubusercontent.com/longhorn/longhorn/v1.2.4/deploy/longhorn-images.txt -o ./longhorn/longhorn-images.txt

# skopeo cert-manager
for i in $(cat cert/cert-manager-images.txt); do 
  skopeo copy docker://$i docker-archive:cert/$(echo $i| awk -F/ '{print $3}'|sed 's/:/_/g').tar:$(echo $i| awk -F/ '{print $3}') 
done

# skopeo - longhorn
for i in $(cat longhorn/longhorn-images.txt); do 
  skopeo copy docker://$i docker-archive:longhorn/$(echo $i| awk -F/ '{print $2}'|sed 's/:/_/g').tar:$(echo $i| awk -F/ '{print $2}') 
done

# skopeo - Rancher - This will take time getting all the images
for i in $(cat rancher/rancher-images.txt); do 
  skopeo copy docker://$i docker-archive:rancher/$(echo $i| awk -F/ '{print $2}'|sed 's/:/_/g').tar:$(echo $i| awk -F/ '{print $2}') &
done

```

### Get Nerdctl

```bash
# in order to server out the images we need a utility called nerctl
mkdir /root/nerdctl/
cd /root/nerdctl/

curl -#LO https://github.com/containerd/nerdctl/releases/download/v0.18.0/nerdctl-0.18.0-linux-amd64.tar.gz

# for later
chmod 755 /usr/local/bin/nerdctl
ln -s /run/k3s/containerd/containerd.sock /run/containerd/containerd.sock
ln -s /usr/local/bin/nerdctl /usr/local/bin/docker
```

### Package and Move all the bits

For this guide we do not actually need to package and move all the bits. We are going to install from this location. If this was an actual air gapped situation we would need to sneaker net the tarball over.

```bash
# cd /root
cd /root

# compress all the things
tar -zvcf rke2_rancher_longhorn.tgz helm rke2 images nerdctl
```

----- STOP ------

I should finish this.

![success](img/success.jpg)
