#!/usr/bin/env bash

# This is a function library, expected to be source'd

# These are the versions in the OLM Subscriptions, but they will be
# updated to the currentCSV version in the corresponding package in
# the catalog source.
KNATIVE_SERVING_VERSION=v0.3.0
KNATIVE_BUILD_VERSION=v0.3.0
KNATIVE_EVENTING_VERSION=v0.3.0

INSTALL_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

CMD=kubectl
if hash oc 2>/dev/null; then
  CMD=$_
fi

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
  timeout 300 "$CMD get pods -n $1 2>&1 | grep -v -E '(Running|Completed|STATUS)'"
}

function show_server {
  if [ "$CMD" = "oc" ]; then
    $CMD whoami --show-server
  else
    $CMD cluster-info | head -1
  fi
}

function check_minishift {
  (hash minishift &&
     minishift ip | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" &&
     show_server | grep "$(minishift ip)"
  ) >/dev/null 2>&1
}

function check_minikube {
  (hash minikube &&
     minikube ip | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" &&
     show_server | grep "$(minikube ip)"
  ) >/dev/null 2>&1
}

function check_openshift_4 {
  $CMD api-resources | grep machineconfigs | grep machineconfiguration.openshift.io > /dev/null 2>&1
}

function check_operatorgroups {
  $CMD get crd operatorgroups.operators.coreos.com >/dev/null 2>&1
}

function enable_admission_webhooks {
  if check_openshift_4; then
    echo "Detected OpenShift 4 - skipping enabling admission webhooks"
  elif check_minikube; then
    echo "Detected minikube - assuming admission webhooks enabled via --extra-config"
  elif check_minishift; then
    echo "Detected minishift - checking if admission webhooks are enabled."
    if ! minishift openshift config view --target=kube | grep ValidatingAdmissionWebhook >/dev/null; then
      echo "Admission webhooks are not enabled - enabling now."
      minishift openshift config set --target=kube --patch '{
        "admissionConfig": {
          "pluginConfig": {
            "ValidatingAdmissionWebhook": {
              "configuration": {
                "apiVersion": "apiserver.config.k8s.io/v1alpha1",
                "kind": "WebhookAdmission",
                "kubeConfigFile": "/dev/null"
              }
            },
            "MutatingAdmissionWebhook": {
              "configuration": {
                "apiVersion": "apiserver.config.k8s.io/v1alpha1",
                "kind": "WebhookAdmission",
                "kubeConfigFile": "/dev/null"
              }
            }
          }
        }
      }'
      # wait until the kube-apiserver is restarted
      until oc login -u admin -p admin 2>/dev/null; do sleep 5; done;
    else
      echo "Admission webhooks are already enabled."
    fi
  else
    echo "Attempting to enable admission webhooks via SSH."
    KUBE_SSH_USER=${KUBE_SSH_USER:-cloud-user}
    API_SERVER=$($CMD config view --minify | grep server | awk -F'//' '{print $2}' | awk -F':' '{print $1}')

    ssh $KUBE_SSH_USER@$API_SERVER -i $KUBE_SSH_KEY /bin/bash <<- EOF
	sudo -i
	cp -n /etc/origin/master/master-config.yaml /etc/origin/master/master-config.yaml.backup
	oc ex config patch /etc/origin/master/master-config.yaml --type=merge -p '{
	  "admissionConfig": {
	    "pluginConfig": {
	      "ValidatingAdmissionWebhook": {
	        "configuration": {
	          "apiVersion": "apiserver.config.k8s.io/v1alpha1",
	          "kind": "WebhookAdmission",
	          "kubeConfigFile": "/dev/null"
	        }
	      },
	      "MutatingAdmissionWebhook": {
	        "configuration": {
	          "apiVersion": "apiserver.config.k8s.io/v1alpha1",
	          "kind": "WebhookAdmission",
	          "kubeConfigFile": "/dev/null"
	        }
	      }
	    }
	  }
	}' >/etc/origin/master/master-config.yaml.patched
	if [ $? == 0 ]; then
	  mv /etc/origin/master/master-config.yaml.patched /etc/origin/master/master-config.yaml
	  /usr/local/bin/master-restart api && /usr/local/bin/master-restart controllers
	else
	  exit
	fi
	EOF

    if [ $? == 0 ]; then
      # wait until the kube-apiserver is restarted
      until oc status 2>/dev/null; do sleep 5; done
    else
      echo 'Remote command failed; check $KUBE_SSH_USER and/or $KUBE_SSH_KEY'
      return -1
    fi
  fi
}

function install_olm {
  local ROOT_DIR="$INSTALL_SCRIPT_DIR/../.."
  local OLM_NS="operator-lifecycle-manager"
  if check_openshift_4; then
    echo "Detected OpenShift 4 - skipping OLM installation."
    OLM_NS="openshift-operator-lifecycle-manager"
  elif $CMD get ns "$OLM_NS" 2>/dev/null; then
    echo "Detected OpenShift 3 with OLM already installed."
    # we'll assume this is v3.11.0, which doesn't support
    # OperatorGroups, or ClusterRoles in the CSV, so...
    oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:istio-operator:istio-operator
    oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:knative-build:build-controller
    oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:knative-serving:controller
    oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:knative-eventing:default
  else
    local REPO_DIR="$ROOT_DIR/.repos"
    local OLM_DIR="$REPO_DIR/olm"
    mkdir -p "$REPO_DIR"
    rm -rf "$OLM_DIR"
    git clone https://github.com/operator-framework/operator-lifecycle-manager "$OLM_DIR"
    pushd $OLM_DIR; git checkout eaf605cca864e; popd
    for i in "$OLM_DIR"/deploy/okd/manifests/latest/*.crd.yaml; do $CMD apply -f $i; done
    for i in $(find "$OLM_DIR/deploy/okd/manifests/latest/" -type f ! -name "*crd.yaml" | sort); do $CMD create -f $i; done
    wait_for_all_pods openshift-operator-lifecycle-manager
    # perms required by the OLM console: $OLM_DIR/scripts/run_console_local.sh
    # oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:kube-system:default
    # check our namespace
    OLM_NS=$(grep "catalog_namespace:" "$OLM_DIR/deploy/okd/values.yaml" | awk '{print $2}')
  fi
  # and finally apply the catalog sources
  $CMD apply -f "$ROOT_DIR/knative-operators.catalogsource.yaml" -n "$OLM_NS"
  $CMD apply -f "$ROOT_DIR/maistra-operators.catalogsource.yaml" -n "$OLM_NS"
}

function install_istio {
  if check_minikube; then
    echo "Detected minikube - incompatible with Maistra operator, so installing upstream istio."
    $CMD apply -f "https://github.com/knative/serving/releases/download/${KNATIVE_SERVING_VERSION}/istio-crds.yaml" && \
    $CMD apply -f "https://github.com/knative/serving/releases/download/${KNATIVE_SERVING_VERSION}/istio.yaml"
    wait_for_all_pods istio-system
  else
    $CMD create ns istio-operator
    if check_operatorgroups; then
      cat <<-EOF | $CMD apply -f -
	apiVersion: operators.coreos.com/v1alpha2
	kind: OperatorGroup
	metadata:
	  name: istio-operator
	  namespace: istio-operator
	EOF
    fi
    cat <<-EOF | $CMD apply -f -
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

    cat <<-EOF | $CMD apply -f -
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
    timeout 900 '$CMD get pods -n istio-system && [[ $($CMD get pods -n istio-system | grep openshift-ansible-istio-installer | grep -c Completed) -eq 0 ]]'

    # Scale down unused services deployed by the istio operator. The
    # jaeger pods will fail anyway due to the elasticsearch pod failing
    # due to "max virtual memory areas vm.max_map_count [65530] is too
    # low, increase to at least [262144]" which could be mitigated on
    # minishift with:
    #  minishift ssh "echo 'echo vm.max_map_count = 262144 >/etc/sysctl.d/99-elasticsearch.conf' | sudo sh"
    $CMD scale -n istio-system --replicas=0 deployment/grafana
    $CMD scale -n istio-system --replicas=0 deployment/jaeger-collector
    $CMD scale -n istio-system --replicas=0 deployment/jaeger-query
    $CMD scale -n istio-system --replicas=0 statefulset/elasticsearch
  fi
}

function install_knative_build {
  $CMD create ns knative-build
  if check_operatorgroups; then
    cat <<-EOF | $CMD apply -f -
	apiVersion: operators.coreos.com/v1alpha2
	kind: OperatorGroup
	metadata:
	  name: knative-build
	  namespace: knative-build
	EOF
  fi
  cat <<-EOF | $CMD apply -f -
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
	EOF
}

function install_knative_serving {
  $CMD create ns knative-serving
  if check_operatorgroups; then
    cat <<-EOF | $CMD apply -f -
	apiVersion: operators.coreos.com/v1alpha2
	kind: OperatorGroup
	metadata:
	  name: knative-serving
	  namespace: knative-serving
	EOF
  fi
  cat <<-EOF | $CMD apply -f -
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
	EOF
}

function install_knative_eventing {
  $CMD create ns knative-eventing
  if check_operatorgroups; then
    cat <<-EOF | $CMD apply -f -
	apiVersion: operators.coreos.com/v1alpha2
	kind: OperatorGroup
	metadata:
	  name: knative-eventing
	  namespace: knative-eventing
	EOF
  fi
  cat <<-EOF | $CMD apply -f -
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
}
