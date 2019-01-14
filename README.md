# Knative Operators

To install the operators in your cluster running the
[OLM](https://github.com/operator-framework/operator-lifecycle-manager):

    # Namespace should be what the OLM catalog operator is watching
    $ kubectl apply -n operator-lifecycle-manager -f https://raw.githubusercontent.com/openshift-cloud-functions/knative-operators/master/knative-operators.catalogsource.yaml

To regenerate the `CatalogSource` and its associated `ConfigMap` from
the source files beneath [olm-catalog/](olm-catalog/):

    $ ./etc/scripts/catalog.sh >knative-operators.catalogsource.yaml

To install everything on a fresh minishift:

    $ ./etc/scripts/install-on-minishift.sh

To install everything on any OpenShift cluster:

    $ oc login <<< with plenty of admin creds >>>
    $ export KUBE_SSH_USER=ec2-user
    $ export KUBE_SSH_KEY=~/.ssh/ocp-workshop.pem
    $ ./etc/scripts/install.sh
