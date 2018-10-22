#!/bin/bash 

set -x

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
until oc login -u admin -p admin; do sleep 5; done;

oc project myproject
oc adm policy add-scc-to-user privileged -z default
oc label namespace myproject istio-injection=enabled

curl -s https://raw.githubusercontent.com/knative/docs/master/install/scripts/istio-openshift-policies.sh | bash

oc apply -f https://storage.googleapis.com/knative-releases/serving/latest/istio.yaml

oc get cm istio-sidecar-injector -n istio-system -oyaml | sed -e 's/securityContext:/securityContext:\\n      privileged: true/' | oc replace -f -

while oc get pods -n istio-system | grep -v -E "(Running|Completed|STATUS)"; do sleep 5; done

curl -s https://raw.githubusercontent.com/knative/docs/master/install/scripts/knative-openshift-policies.sh | bash

# for the OLM console
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:kube-system:default
