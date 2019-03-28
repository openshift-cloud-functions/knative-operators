#!/usr/bin/env bash

# WARNING: this totally destroys and recreates your `knative` profile,
# thereby guaranteeing (hopefully) a clean environment upon successful
# completion.

if minishift status | head -1 | grep "Running" >/dev/null; then
  echo "Please stop your running minishift to acknowledge this script will destroy it."
  exit 1
fi

set -x

OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-v3.11.0}
MEMORY=${MEMORY:-10GB}
CPUS=${CPUS:-4}
DISK_SIZE=${DISK_SIZE:-50g}

if [ -z "${VM_DRIVER}" ]; then
  # check for default driver
  VM_DRIVER=$(minishift config get vm-driver --profile minishift)
  if [ -z "$VM_DRIVER" ] || [ $VM_DRIVER = "<nil>" ]; then
    if [[ -z "${OSTYPE}" && $(uname) == "Darwin" ]] || [ "${OSTYPE#darwin}" != "${OSTYPE}" ]; then
      # set hyperkit as default on macOs
      VM_DRIVER="hyperkit"
    else
      # no driver to set
      VM_DRIVER=""
    fi
  fi
fi

# blow away everything in the knative profile
minishift profile delete knative --force >/dev/null 2>&1

# configure knative profile
minishift profile set knative
minishift config set openshift-version ${OPENSHIFT_VERSION}
minishift config set memory ${MEMORY}
minishift config set cpus ${CPUS}
minishift config set disk-size ${DISK_SIZE}
minishift config set image-caching true
if [ -n "${VM_DRIVER}" ]; then
  minishift config set vm-driver ${VM_DRIVER}
fi

minishift addons enable admin-user

# Start minishift
minishift start

eval "$(minishift oc-env)"

oc login -u admin -p admin

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
"$DIR/install.sh" -q
