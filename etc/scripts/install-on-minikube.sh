#!/usr/bin/env bash

# WARNING: this totally destroys and recreates your `knative` profile,
# thereby guaranteeing (hopefully) a clean environment upon successful
# completion.

if minikube status 2>&1 | grep -E "^E[0-9]{4}"; then
  echo "minikube is confused, check for conflicting vm's, e.g. minishift"
  exit -1
fi
if minikube status | head -1 | grep "Running" >/dev/null; then
  echo "Please stop your running minikube to acknowledge this script will destroy it."
  exit 1
fi

set -x

KUBERNETES_VERSION=${KUBERNETES_VERSION:-v1.12.0}
MEMORY=${MEMORY:-8192}
CPUS=${CPUS:-4}
DISK_SIZE=${DISK_SIZE:-50g}
VM_DRIVER=${VM_DRIVER:-$(minikube config get vm-driver 2>/dev/null || echo "virtualbox")}

# configure knative profile
minikube profile knative
minikube config set kubernetes-version ${KUBERNETES_VERSION}
minikube config set memory ${MEMORY}
minikube config set cpus ${CPUS}
minikube config set disk-size ${DISK_SIZE}
minikube config set vm-driver ${VM_DRIVER}

# blow away everything in the knative profile
minikube delete

# Start minikube
minikube start -p knative --extra-config=apiserver.enable-admission-plugins="LimitRanger,NamespaceExists,NamespaceLifecycle,ResourceQuota,ServiceAccount,DefaultStorageClass,MutatingAdmissionWebhook"

if [ $? -eq 0 ]; then
  DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
  "$DIR/install.sh" -q
else
  echo "Failed to start minikube!"
  exit -1
fi
