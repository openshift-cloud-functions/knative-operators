#!/usr/bin/env bash

# Installs istio, OLM and all knative operators on minishift

# WARNING: it totally destroys and recreates your `knative` profile,
# thereby guaranteeing (hopefully) a clean environment upon successful
# completion. 

KNATIVE_SERVING_VERSION=v0.2.2
KNATIVE_BUILD_VERSION=v0.2.0
KNATIVE_EVENTING_VERSION=v0.2.0

DIR=$(cd $(dirname "$0") && pwd)
ROOT_DIR=$DIR/../..
REPO_DIR=$ROOT_DIR/.repos

set -x

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

# initialize local repos dir
rm -rf "$REPO_DIR"
mkdir -p "$REPO_DIR"

# initialize the minishift knative profile
"$DIR/init-minishift-for-knative.sh"

# OLM
git clone https://github.com/operator-framework/operator-lifecycle-manager "$REPO_DIR/olm"
cat $REPO_DIR/olm/deploy/okd/manifests/latest/*.crd.yaml | oc apply -f -
sleep 1
find $REPO_DIR/olm/deploy/okd/manifests/latest/ -type f ! -name "*crd.yaml" | sort | xargs cat | oc create -f -
wait_for_all_pods openshift-operator-lifecycle-manager
# perms required by the OLM console: $REPO_DIR/olm/scripts/run_console_local.sh 
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:kube-system:default

# knative catalog source
oc apply -f "$ROOT_DIR/knative-operators.catalogsource.yaml"
oc apply -f "$ROOT_DIR/maistra-operators.catalogsource.yaml"

# istio
oc create ns istio-operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: maistra
  namespace: istio-operator
spec:
  channel: alpha
  name: maistra
  source: maistra-operators
EOF
wait_for_all_pods istio-operator

cat <<EOF | oc apply -f -
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

# Scale down unused services deployed by the istio addon. The jaeger
# pods will fail anyway due to the elasticsearch pod failing due to
# "max virtual memory areas vm.max_map_count [65530] is too low,
# increase to at least [262144]" which could be mitigated on minishift
# with:
#  minishift ssh "echo 'echo vm.max_map_count = 262144 >/etc/sysctl.d/99-elasticsearch.conf' | sudo sh"
oc scale -n istio-system --replicas=0 deployment/grafana
oc scale -n istio-system --replicas=0 deployment/jaeger-collector
oc scale -n istio-system --replicas=0 deployment/jaeger-query
oc scale -n istio-system --replicas=0 statefulset/elasticsearch

# for now, we must install the operators in specific namespaces, so...
oc create ns knative-build
oc create ns knative-serving
oc create ns knative-eventing

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

wait_for_all_pods knative-build
wait_for_all_pods knative-eventing
wait_for_all_pods knative-serving

# skip tag resolving for internal registry
oc -n knative-serving get cm config-controller -oyaml | sed "s/\(^ *registriesSkippingTagResolving.*$\)/\1,docker-registry.default.svc:5000/" | oc apply -f -

# Add Golang imagestreams to be able to build go based images
oc import-image -n openshift golang --from=centos/go-toolset-7-centos7 --confirm
oc import-image -n openshift golang:1.11 --from=centos/go-toolset-7-centos7 --confirm

# show all the pods
oc get pods --all-namespaces
