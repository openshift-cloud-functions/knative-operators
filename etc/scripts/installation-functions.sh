#!/usr/bin/env bash

# This is a function library, expected to be source'd

# These are the versions in the OLM Subscriptions, but they will be
# updated to the currentCSV version in the corresponding package in
# the catalog source.
KNATIVE_SERVING_VERSION=v0.5.1
KNATIVE_BUILD_VERSION=v0.5.0
KNATIVE_EVENTING_VERSION=v0.5.0

readonly ISTIO_IMAGE_REPO="docker.io/istio/"
readonly ISTIO_PATCH_VERSION="1.0.7"

INSTALL_SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

CMD=kubectl
if hash oc 2>/dev/null; then
  CMD=$_
fi

# Loops until duration (car) is exceeded or command (cdr) returns success
function timeout() {
  SECONDS=0; TIMEOUT=$1; shift
  until eval $*; do
    sleep 5
    [[ $SECONDS -gt $TIMEOUT ]] && echo "ERROR: Timed out" && exit -1
  done
}

# Waits for all pods in the given namespace to complete successfully.
function wait_for_all_pods {
  timeout 300 "$CMD get pods -n $1 && [[ \$($CMD get pods -n $1 2>&1 | grep -c -v -E '(Running|Completed|Terminating|STATUS)') -eq 0 ]]"
}

# Waits for a particular deployment to have all its pods available
# usage: wait_for_deployment namespace name
function wait_for_deployment {
  timeout 300 "$CMD get deploy -n $1 && [[ \$($CMD get deploy -n $1 | grep -E '[1-9]\d*\s+\S+$' | grep -c $2) -eq 1 ]]"
}

function show_server {
  if [ "$CMD" = "oc" ]; then
    $CMD whoami --show-server
  else
    $CMD cluster-info | head -1
  fi
}

function olm_namespace {
  $CMD get pods --all-namespaces | grep olm-operator | head -1 | awk '{print $1}'
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
  if $CMD api-resources >/dev/null; then
    $CMD api-resources | grep machineconfigs | grep machineconfiguration.openshift.io > /dev/null 2>&1
  else
    ($CMD get ns openshift && $CMD version | tail -1 | grep "v1.12") >/dev/null 2>&1
  fi
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
  elif [ "$KUBE_SSH_USER" != "" ]; then
    echo "Attempting to enable admission webhooks via SSH."
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
  else
    echo "Unable to enable admission webhooks - if necessary, set KUBE_SSH_USER and retry"
  fi
}

function install_olm {
  if check_openshift_4; then
    echo "Detected OpenShift 4 - skipping OLM installation."
  elif $CMD get ns "operator-lifecycle-manager" 2>/dev/null; then
    echo "Detected OpenShift 3 with an older OLM already installed."
    # we'll assume this is v3.11.0, which doesn't support
    # OperatorGroups, or ClusterRoles in the CSV, so...
    oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:istio-operator:istio-operator
    oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:knative-build:build-controller
    oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:knative-serving:controller
    oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:knative-eventing:default
  elif [ "$(olm_namespace)" = "" ]; then
    $CMD apply -f https://github.com/operator-framework/operator-lifecycle-manager/releases/download/0.9.0/olm.yaml
    wait_for_all_pods olm
    # perms required by the OLM console: $OLM_DIR/scripts/run_console_local.sh
    # oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:kube-system:default
  else
    echo "Detected OLM - skipping installation"
  fi
}

function install_catalogsources {
  local ROOT_DIR="$INSTALL_SCRIPT_DIR/../.."
  local OLM_NS=$(olm_namespace)
  $CMD apply -n "$OLM_NS" -f https://raw.githubusercontent.com/openshift/knative-serving/release-${KNATIVE_SERVING_VERSION}/openshift/olm/knative-serving.catalogsource.yaml
  $CMD apply -n "$OLM_NS" -f https://raw.githubusercontent.com/openshift/knative-build/release-${KNATIVE_BUILD_VERSION}/openshift/olm/knative-build.catalogsource.yaml
  $CMD apply -n "$OLM_NS" -f https://raw.githubusercontent.com/openshift/knative-eventing/release-${KNATIVE_EVENTING_VERSION}/openshift/olm/knative-eventing.catalogsource.yaml
  $CMD apply -f "$ROOT_DIR/maistra-operators.catalogsource.yaml" -n "$OLM_NS"
  timeout 120 "$CMD get pods -n $OLM_NS | grep knative"
  timeout 120 "$CMD get pods -n $OLM_NS | grep maistra"
  wait_for_all_pods "$OLM_NS"
}

function install_istio {
  if $CMD get ns "istio-system" 2>/dev/null; then
    echo "Detected istio - skipping installation"
  elif check_minikube; then
    echo "Detected minikube - incompatible with Maistra operator, so installing upstream istio."
    $CMD apply -f "https://github.com/knative/serving/releases/download/${KNATIVE_SERVING_VERSION}/istio-crds.yaml" && \
    $CMD apply -f "https://github.com/knative/serving/releases/download/${KNATIVE_SERVING_VERSION}/istio.yaml"
    wait_for_all_pods istio-system
  else
    $CMD create ns istio-operator
    if check_operatorgroups; then
      cat <<-EOF | $CMD apply -f -
	apiVersion: operators.coreos.com/v1
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
	  sourceNamespace: $(olm_namespace)
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
	  kiali:
	    username: admin
	    password: admin
	    prefix: kiali/
	EOF
    timeout 900 '$CMD get pods -n istio-system && [[ $($CMD get pods -n istio-system | grep openshift-ansible-istio-installer | grep -c Completed) -gt 0 ]]'

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

    patch_istio_for_knative
  fi
}

function install_knative {
  local version
  case $1 in
    build)
      version=$KNATIVE_BUILD_VERSION
      ;;
    serving)
      version=$KNATIVE_SERVING_VERSION
      ;;
    eventing)
      version=$KNATIVE_EVENTING_VERSION
      ;;
    *)
      echo "Pass one of 'build', 'serving', or 'eventing'"
      return -1
      ;;
  esac
  local COMPONENT="knative-$1"
  if $CMD get ns ${COMPONENT} 2>/dev/null 1>&2; then
    echo "${COMPONENT} namespace exists - reapplying resources"
  else
    $CMD create ns ${COMPONENT}
  fi
  if check_operatorgroups; then
    cat <<-EOF | $CMD apply -f -
	apiVersion: operators.coreos.com/v1
	kind: OperatorGroup
	metadata:
	  name: ${COMPONENT}
	  namespace: ${COMPONENT}
	EOF
  fi
  cat <<-EOF | $CMD apply -f -
	apiVersion: operators.coreos.com/v1alpha1
	kind: Subscription
	metadata:
	  name: ${COMPONENT}-subscription
	  generateName: ${COMPONENT}-
	  namespace: ${COMPONENT}
	spec:
	  source: ${COMPONENT}-operator
	  sourceNamespace: $(olm_namespace)
	  name: ${COMPONENT}-operator
	  startingCSV: ${COMPONENT}-operator.${version}
	  channel: alpha
	EOF
}

function enable_interaction_with_registry() {
  if check_openshift_4; then
    local ns=${1:-knative-serving}
    local configmap_name=config-service-ca
    local cert_name=service-ca.crt
    local mount_path=/var/run/secrets/kubernetes.io/servicecerts

    $CMD -n $ns create configmap $configmap_name
    $CMD -n $ns annotate configmap $configmap_name service.alpha.openshift.io/inject-cabundle="true"
    timeout 180 '$CMD -n $ns get cm $configmap_name -oyaml | grep $cert_name'
    $CMD -n $ns set volume deployment/controller --add --name=service-ca --configmap-name=$configmap_name --mount-path=$mount_path
    $CMD -n $ns set env deployment/controller SSL_CERT_FILE=$mount_path/$cert_name
  else
    echo "Registry configuration only required for OCP4"
  fi
}

function patch_istio_for_knative() {
  local sidecar_config=$($CMD get configmap -n istio-system istio-sidecar-injector -o yaml)
  if [[ -z "${sidecar_config}" ]]; then
    return 1
  fi
  echo "${sidecar_config}" | grep lifecycle
  if [[ $? -eq 1 ]]; then
    echo "Patching Istio's preStop hook for graceful shutdown"
    echo "${sidecar_config}" | sed 's/\(name: istio-proxy\)/\1\\n    lifecycle:\\n      preStop:\\n        exec:\\n          command: [\\"sh\\", \\"-c\\", \\"sleep 20; while [ $(netstat -plunt | grep tcp | grep -v envoy | wc -l | xargs) -ne 0 ]; do sleep 1; done\\"]/' | $CMD replace -f -
    $CMD delete pod -n istio-system -l istio=sidecar-injector
    wait_for_all_pods istio-system
  fi

  # Patch the sidecar injector configmap up to $ISTIO_PATCH_VERSION
  oc get -n istio-system configmap/istio-sidecar-injector -o yaml | sed "s/:1.0.[[:digit:]]\+/:${ISTIO_PATCH_VERSION}/g" | oc replace -f -

  # Ensure Istio $ISTIO_PATCH_VERSION is used everywhere
  echo "Patching Istio images up to $ISTIO_PATCH_VERSION"
  patch_istio_deployment istio-galley 0 galley || return 1
  patch_istio_deployment istio-egressgateway 0 proxyv2 || return 1
  patch_istio_deployment istio-ingressgateway 0 proxyv2 || return 1
  patch_istio_deployment istio-policy 0 mixer || return 1
  patch_istio_deployment istio-policy 1 proxyv2 || return 1
  patch_istio_deployment istio-telemetry 0 mixer || return 1
  patch_istio_deployment istio-telemetry 1 proxyv2 || return 1
  patch_istio_deployment istio-pilot 0 pilot || return 1
  patch_istio_deployment istio-pilot 1 proxyv2 || return 1
  patch_istio_deployment istio-citadel 0 citadel || return 1
  patch_istio_deployment istio-sidecar-injector 0 sidecar_injector || return 1

  wait_for_deployment istio-system istio-galley
  wait_for_all_pods istio-system || return 1
}

function patch_istio_deployment() {
  local deployment="$1"
  local containerIndex=$2
  local imageName=$3
  oc patch -n istio-system deployment/${deployment} --type json -p "[{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/${containerIndex}/image\", \"value\":\"${ISTIO_IMAGE_REPO}${imageName}:${ISTIO_PATCH_VERSION}\"}]"
}
