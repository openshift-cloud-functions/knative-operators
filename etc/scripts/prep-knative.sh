#!/usr/bin/env bash 

set -x

if ! minishift openshift config view --target=kube | grep ValidatingAdmissionWebhook >/dev/null; then
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
fi

# wait until the kube-apiserver is restarted
until oc login -u admin -p admin 2>/dev/null; do sleep 5; done;

oc project myproject
until oc adm policy add-scc-to-user privileged -z default; do sleep 5; done

# for the OLM console
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:kube-system:default
