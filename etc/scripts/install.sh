#!/usr/bin/env bash

# Attempts to install istio, knative, and OLM, ideally not in that order.

if [ "$1" != "-q" ]; then
  echo
  echo "  This script will attempt to install istio, knative, and OLM in your "
  echo "  Kubernetes/OpenShift cluster."
  echo
  echo "  If targeting OpenShift, a recent version of 'oc' should be available"
  echo "  in your PATH. Otherwise, 'kubectl' will be used."
  echo
  echo "  If using OpenShift 3.11 and your cluster isn't minishift, ensure"
  echo "  \$KUBE_SSH_KEY and \$KUBE_SSH_USER are set"
  echo
  echo "  Pass -q to disable this prompt"
  echo
  read -p "Enter to continue or Ctrl-C to exit: "
fi

set -x

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

source "$DIR/installation-functions.sh"

enable_admission_webhooks
install_olm
install_istio
install_knative_build
install_knative_serving
install_knative_eventing

wait_for_all_pods knative-build
wait_for_all_pods knative-eventing
wait_for_all_pods knative-serving

# skip tag resolving for internal registry
# OpenShift 3 and 4 place the registry in different locations, hence
# the two hostnames here
$CMD -n knative-serving get cm config-controller -oyaml | sed "s/\(^ *registriesSkippingTagResolving.*$\)/\1,docker-registry.default.svc:5000,image-registry.openshift-image-registry.svc:5000/" | oc apply -f -

if $CMD get ns openshift 2>/dev/null; then
  # Add Golang imagestreams to be able to build go based images
  oc import-image -n openshift golang --from=centos/go-toolset-7-centos7 --confirm
  oc import-image -n openshift golang:1.11 --from=centos/go-toolset-7-centos7 --confirm

  if ! oc project myproject 2>/dev/null; then
    oc new-project myproject
  fi
  # these perms are required by istio
  oc adm policy add-scc-to-user privileged -z default
  oc adm policy add-scc-to-user anyuid -z default
else
  $CMD create namespace myproject
fi

# show all the running pods
$CMD get pods --all-namespaces
