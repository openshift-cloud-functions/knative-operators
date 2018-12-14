#!/usr/bin/env bash

# Installs OLM first, and then istio and knative using OLM operators

if [ "$1" != "-q" ]; then
  echo
  echo "  WARNING: This script will blindly attempt to install OLM, istio, and knative"
  echo "  on your OKD cluster, so if any are already there, hijinks will ensue."
  echo
  echo "  If your cluster is minishift, run $(dirname $0)/install-on-minishift.sh instead."
  echo
  echo "  Pass -q to disable this warning"
  echo
  read -p "Enter to continue or Ctrl-C to exit: "
fi

set -x

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"

source "$DIR/install-functions.sh"

install_olm
install_istio
install_knative_build
install_knative_serving
install_knative_eventing

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
