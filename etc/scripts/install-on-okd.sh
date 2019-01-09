#!/usr/bin/env bash

function enable_admission_webhooks {

  API_SERVER=$(oc config view --minify | grep server | awk -F'//' '{print $2}' | awk -F':' '{print $1}')
  KUBE_SSH_USER="cloud-user"

  echo "API_SERVER=$API_SERVER"
  echo "KUBE_SSH_USER=$KUBE_SSH_USER"
  echo "KUBE_SSH_KEY=$KUBE_SSH_KEY"
  
  ssh $KUBE_SSH_USER@$API_SERVER -i $KUBE_SSH_KEY /bin/bash << "EOF"
  sudo su - root
  cp -n /etc/origin/master/master-config.yaml /etc/origin/master/master-config.yaml.backup
  cp -p /etc/origin/master/master-config.yaml /etc/origin/master/master-config.yaml.prepatch
  cat > /etc/origin/master/master-config.patch << EOT
admissionConfig:
  pluginConfig:
    MutatingAdmissionWebhook:
      configuration:
        apiVersion: apiserver.config.k8s.io/v1alpha1
        kubeConfigFile: /dev/null
        kind: WebhookAdmission
    ValidatingAdmissionWebhook:
      configuration:
        apiVersion: apiserver.config.k8s.io/v1alpha1
        kubeConfigFile: /dev/null
        kind: WebhookAdmission
EOT

  oc ex config patch /etc/origin/master/master-config.yaml.prepatch -p "$(cat /etc/origin/master/master-config.patch)" > /etc/origin/master/master-config.yaml
  /usr/local/bin/master-restart api && /usr/local/bin/master-restart controllers

  rm /etc/origin/master/master-config.yaml.prepatch /etc/origin/master/master-config.patch
  
EOF

   # wait until the kube-apiserver is restarted
   until oc login -u system:admin 2>/dev/null; do sleep 5; done;
}

if [ -z "$KUBE_SSH_KEY" ]
then
  echo "  In order for admission webhooks to be enabled, you need to set \$KUBE_SSH_KEY variable,"
  echo "  pointing to private SSH key for the cloud-user account."
  echo "  \$KUBE_SSH_KEY is empty - aborting."
  exit 1
fi

set -x

enable_admission_webhooks

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null && pwd )"
"$DIR/install.sh" -q
