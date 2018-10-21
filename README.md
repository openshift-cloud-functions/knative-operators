# Knative Operators

To install the operators in your cluster running the
[OLM](https://github.com/operator-framework/operator-lifecycle-manager):

    $ kubectl apply -f https://raw.githubusercontent.com/openshift-cloud-functions/knative-operators/master/knative-operators.catalogsource.yaml

To regenerate the `CatalogSource` and its associated `ConfigMap` from
the source files beneath [olm-catalog/](olm-catalog/):

    $ ./etc/scripts/catalog.sh >knative-operators.catalogsource.yaml
