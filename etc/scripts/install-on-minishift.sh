#!/usr/bin/env bash 

# WARNING: this totally destroys and recreates your `knative` profile,
# thereby guaranteeing (hopefully) a clean environment upon successful
# completion.

if minishift status | grep "Minishift:  Running" >/dev/null; then
  echo "Please stop your running minishift to acknowledge this script will destroy it."
  exit 1
fi

set -x

# blow away everything in the knative profile
minishift profile delete knative --force

# configure knative profile
minishift profile set knative
minishift config set openshift-version v3.11.0
minishift config set memory 10GB
minishift config set cpus 4
minishift config set disk-size 50g
minishift config set image-caching true
minishift addons enable admin-user

# Start minishift
minishift start

eval "$(minishift oc-env)"

oc login -u admin -p admin

# these perms are required by istio
oc project myproject
until oc adm policy add-scc-to-user privileged -z default; do sleep 5; done
oc adm policy add-scc-to-user anyuid -z default

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
"$DIR/install.sh" -q
