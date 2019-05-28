# WARNING!

This repo is becoming obsolete. For current knative operator work, see
[this poorly-named repo](https://github.com/openshift-knative) instead.

# Knative Operators

To install everything on a fresh minishift:

    $ ./etc/scripts/install-on-minishift.sh

To install everything on a fresh minikube:

    $ ./etc/scripts/install-on-minikube.sh

To install everything on any OpenShift cluster:

    $ oc login <<< with plenty of admin creds >>>
    $ ./etc/scripts/install.sh
