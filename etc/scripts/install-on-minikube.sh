#!/usr/bin/env bash

# WARNING: this totally destroys and recreates your `knative` profile,
# thereby guaranteeing (hopefully) a clean environment upon successful
# completion.

if minikube status | grep "host: Running" >/dev/null; then
  echo "Please stop your running minikube to acknowledge this script will destroy it."
  exit 1
fi

set -x

# blow away everything in the knative profile
minikube delete --profile knative

# configure knative profile
minikube profile knative
minikube config set kubernetes-version v1.11.5 -p knative
minikube config set memory 10240 -p knative
minikube config set cpus 4 -p knative
minikube config set disk-size 50g -p knative

# Start minikube
minikube start -p knative --extra-config=apiserver.enable-admission-plugins="LimitRanger,NamespaceExists,NamespaceLifecycle,ResourceQuota,ServiceAccount,DefaultStorageClass,MutatingAdmissionWebhook"

#oc login -u admin -p admin

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
"$DIR/install.sh" -q
