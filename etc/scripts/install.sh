#!/bin/bash

# Installs istio, OLM and all knative operators on minishift

# WARNING: it totally destroys and recreates your `knative` profile,
# thereby guaranteeing (hopefully) a clean environment upon successful
# completion. 

KNATIVE_BUILD_VERSION=v0.2.0
KNATIVE_SERVING_VERSION=v0.2.1
KNATIVE_EVENTING_VERSION=v0.0.0-80860ba

if minishift status | grep "Minishift:  Running" >/dev/null; then
  echo "A running minishift was detected. Please stop it before running this script."
  exit 1
fi

set -x

DIR=$(cd $(dirname "$0") && pwd)
REPO_DIR=$DIR/.repos

rm -rf $REPO_DIR
mkdir -p $REPO_DIR

# blow away everything first
minishift profile delete knative --force

# configure knative profile
minishift profile set knative
minishift config set openshift-version v3.11.0
minishift config set memory 8GB
minishift config set cpus 4
minishift config set disk-size 50g
minishift config set image-caching true
minishift addons enable admin-user
minishift addons enable anyuid

# Start minishift
minishift start

eval $(minishift oc-env)
$DIR/prep-knative.sh

# istio
git clone https://github.com/minishift/minishift-addons $REPO_DIR/minishift-addons
minishift addon install $REPO_DIR/minishift-addons/add-ons/istio
minishift addon apply istio
sleep 10                        # it takes istio a while to start any pods
timeout 300 bash -c -- 'while oc get pods -n istio-system | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done'

# OLM
git clone https://github.com/operator-framework/operator-lifecycle-manager $REPO_DIR/olm
oc create -f $REPO_DIR/olm/deploy/okd/manifests/latest/
timeout 300 bash -c -- 'while oc get pods -n openshift-operator-lifecycle-manager | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done'

# knative catalog source
oc apply -f $DIR/../../knative-operators.catalogsource.yaml

# for now, we must install the operators in specific namespaces, so...
oc new-project knative-build
oc new-project knative-serving
oc new-project knative-eventing

# install the operators for build, serving, and eventing
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: knative-build-subscription
  generateName: knative-build-
  namespace: knative-build
spec:
  source: knative-operators
  name: knative-build
  startingCSV: knative-build.${KNATIVE_BUILD_VERSION}
  channel: alpha
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: knative-serving-subscription
  generateName: knative-serving-
  namespace: knative-serving
spec:
  source: knative-operators
  name: knative-serving
  startingCSV: knative-serving.${KNATIVE_SERVING_VERSION}
  channel: alpha
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: knative-eventing-subscription
  generateName: knative-eventing-
  namespace: knative-eventing
spec:
  source: knative-operators
  name: knative-eventing
  startingCSV: knative-eventing.${KNATIVE_EVENTING_VERSION}
  channel: alpha
EOF
