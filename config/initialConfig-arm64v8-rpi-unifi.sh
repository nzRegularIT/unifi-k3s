#!/bin/bash
hostname="RPi-UniFi"
timeZone="Pacific/Auckland"
sudo hostnamectl --static set-hostname $hostname
sudo timedatectl set-timezone $timeZone
#sudo mkdir /unifi
sudo apt update
sudo apt upgrade -y
sudo apt autoremove -y
sudo apt install net-tools redis-tools -y

# Git config
# Git config requires VS Code helper installed
#git config --global user.email "you@example.com"
#git config --global user.name "Your Name"
git config --global user.name ''
git config --global user.email ''
git config --global credential.helper 'cache --timeout=3600'

# Update config files
dateNow=$(date +%d/%m/%Y)

#sudo sed -i '$ s/$/ cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt
# Ubuntu 20.04 LTS Append to /boot/firmware/cmdline.txt
#sudo sed -i '$ s/$/ cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt
# Ubuntu 18.04 LTS /boot/firmware/nobtcmd.txt
sudo sed -i '$ s/$/ cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/nobtcmd.txt
# Append to /boot/firmware/usercfg.txt
echo \# | sudo tee -a /boot/firmware/usercfg.txt
echo \# Custom config added $dateNow | sudo tee -a /boot/firmware/usercfg.txt
echo gpu_mem_1024=16 | sudo tee -a /boot/firmware/usercfg.txt

# Reboot to apply changes
sudo reboot

# Install k3s
curl -sfL https://get.k3s.io | sudo sh -s - --disable traefik,servicelb

# Temp workaround for k3s.yaml readability for helm to work
sudo chmod 644 /etc/rancher/k3s/k3s.yaml

# Confirm k3s status
systemctl status k3s
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
sudo k3s kubectl get all --all-namespaces

# Install Helm v3
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | sudo bash

# Don't add the Helm 3 repos, takes an inordinate amount of time on RPi!!!
# helm repo add stable https://kubernetes-charts.storage.googleapis.com

# Install MetalLB
#sudo helm install --name metallb --set arpAddresses=192.168.0.21-192.168.0.22 stable/metallb
sudo k3s kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.3/manifests/namespace.yaml
sudo k3s kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.3/manifests/metallb.yaml
sudo k3s kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"

# metalLbConfig.yaml
cat <<EOF | sudo k3s kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - 192.168.0.21-192.168.0.22
EOF

# Create Unifi Controller Namespace
sudo k3s kubectl create namespace unifi-controller

# Install Unifi Controller - testing
helm install unifi ./unifi
sudo k3s kubectl get all --all-namespaces
sudo k3s kubectl describe pods -n unifi-controller unifi-69c789d9f7-mxskz 

# The following are for testing only
: '
# Install Kubernetes Dashboard https://rancher.com/docs/k3s/latest/en/installation/kube-dashboard/
GITHUB_URL=https://github.com/kubernetes/dashboard/releases
VERSION_KUBE_DASHBOARD=$(curl -w '%{url_effective}' -I -L -s -S ${GITHUB_URL}/latest -o /dev/null | sed -e 's|.*/||')
sudo k3s kubectl create -f https://raw.githubusercontent.com/kubernetes/dashboard/${VERSION_KUBE_DASHBOARD}/aio/deploy/recommended.yaml

#dashboard.admin-user.yml
cat <<EOF | sudo k3s kubectl create -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: admin-user
  namespace: kubernetes-dashboard
EOF

#dashboard.admin-user-role.yml
cat <<EOF | sudo k3s kubectl create -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: admin-user
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: admin-user
  namespace: kubernetes-dashboard
EOF

# Get dashboard token
sudo k3s kubectl -n kubernetes-dashboard describe secret admin-user-token | grep ^token

# Create port-forward to dashboard
sudo k3s kubectl port-forward -n kubernetes-dashboard kubernetes-dashboard-7f99b75bf4-g7td9 8443:8443 --address 0.0.0.0


# Create Redis deployment
cat <<EOF | sudo k3s kubectl create -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-master
  labels:
    app: redis
spec:
  selector:
    matchLabels:
      app: redis
      role: master
      tier: backend
  replicas: 1
  template:
    metadata:
      labels:
        app: redis
        role: master
        tier: backend
    spec:
      containers:
      - name: master
        image: arm64v8/redis
        ports:
        - containerPort: 6379
EOF

# Create Redis service
sudo k3s kubectl apply -f https://k8s.io/examples/application/guestbook/redis-master-service.yaml

# Create port forward
sudo k3s kubectl port-forward deployment/redis-master 7000:6379 --address 0.0.0.0

# Test Redis
redis-cli -p 7000
'