#!/usr/bin/env bash

# This is a function library, expected to be source'd

KNATIVE_SERVING_VERSION=v0.2.2
KNATIVE_BUILD_VERSION=v0.2.0
KNATIVE_EVENTING_VERSION=v0.2.0

INSTALL_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

# Loops until duration (car) is exceeded or command (cdr) returns non-zero
function timeout() {
  SECONDS=0; TIMEOUT=$1; shift
  while eval $*; do
    sleep 5
    [[ $SECONDS -gt $TIMEOUT ]] && echo "ERROR: Timed out" && exit -1
  done
}

# Waits for all pods in the given namespace to complete successfully.
function wait_for_all_pods {
  timeout 300 "oc get pods -n $1 2>&1 | grep -v -E '(Running|Completed|STATUS)'"
}

function install_olm {
  local ROOT_DIR="$INSTALL_SCRIPT_DIR/../.."
  local REPO_DIR="$ROOT_DIR/.repos"
  local OLM_DIR="$REPO_DIR/olm"
  mkdir -p "$REPO_DIR"
  rm -rf "$OLM_DIR"
  git clone https://github.com/operator-framework/operator-lifecycle-manager "$OLM_DIR"
  for i in "$OLM_DIR"/deploy/okd/manifests/latest/*.crd.yaml; do oc apply -f $i; done
  for i in $(find "$OLM_DIR/deploy/okd/manifests/latest/" -type f ! -name "*crd.yaml" | sort); do oc create -f $i; done
  wait_for_all_pods openshift-operator-lifecycle-manager
  # perms required by the OLM console: $OLM_DIR/scripts/run_console_local.sh 
  oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:kube-system:default

  # knative catalog source
  oc apply -f "$ROOT_DIR/knative-operators.catalogsource.yaml"
  oc apply -f "$ROOT_DIR/maistra-operators.catalogsource.yaml"
}

function install_istio {
  # istio
  oc create ns istio-operator
  cat <<-EOF | oc apply -f -
	apiVersion: operators.coreos.com/v1alpha1
	kind: Subscription
	metadata:
	  name: maistra
	  namespace: istio-operator
	spec:
	  channel: alpha
	  name: maistra
	  source: maistra-operators
	---
	apiVersion: operators.coreos.com/v1alpha2
	kind: OperatorGroup
	metadata:
	  name: istio-operator
	  namespace: istio-operator
	EOF
  wait_for_all_pods istio-operator

  cat <<-EOF | oc apply -f -
	apiVersion: istio.openshift.com/v1alpha1
	kind: Installation
	metadata:
	  namespace: istio-operator
	  name: istio-installation
	spec:
	  istio:
	    authentication: false
	    community: true
	    version: 0.2.0
	  kiali:
	    username: admin
	    password: admin
	    prefix: kiali/
	    version: v0.7.1
	EOF
  timeout 900 'oc get pods -n istio-system && [[ $(oc get pods -n istio-system | grep openshift-ansible-istio-installer | grep -c Completed) -eq 0 ]]'

  # Scale down unused services deployed by the istio operator. The
  # jaeger pods will fail anyway due to the elasticsearch pod failing
  # due to "max virtual memory areas vm.max_map_count [65530] is too
  # low, increase to at least [262144]" which could be mitigated on
  # minishift with:
  #  minishift ssh "echo 'echo vm.max_map_count = 262144 >/etc/sysctl.d/99-elasticsearch.conf' | sudo sh"
  oc scale -n istio-system --replicas=0 deployment/grafana
  oc scale -n istio-system --replicas=0 deployment/jaeger-collector
  oc scale -n istio-system --replicas=0 deployment/jaeger-query
  oc scale -n istio-system --replicas=0 statefulset/elasticsearch
}

function install_knative_build {
  oc create ns knative-build
  cat <<-EOF | oc apply -f -
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
	apiVersion: operators.coreos.com/v1alpha2
	kind: OperatorGroup
	metadata:
	  name: knative-build
	  namespace: knative-build
	EOF
}

function install_knative_serving {
  oc create ns knative-serving
  cat <<-EOF | oc apply -f -
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
	apiVersion: operators.coreos.com/v1alpha2
	kind: OperatorGroup
	metadata:
	  name: knative-serving
	  namespace: knative-serving
	EOF
}

function install_knative_eventing {
  oc create ns knative-eventing
  cat <<-EOF | oc apply -f -
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
	---
	apiVersion: operators.coreos.com/v1alpha2
	kind: OperatorGroup
	metadata:
	  name: knative-eventing
	  namespace: knative-eventing
	EOF
}
