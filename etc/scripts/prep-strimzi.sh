#!/usr/bin/env bash 

set -x

# Install the Apache Kafka Operator and CRDs from the Strimzi project
oc apply -f https://github.com/strimzi/strimzi-kafka-operator/releases/download/0.8.2/strimzi-cluster-operator-0.8.2.yaml
# Apply a simple cluster with one ZK and one Kafka node
oc apply -f https://raw.githubusercontent.com/strimzi/strimzi-kafka-operator/master/examples/kafka/kafka-persistent-single.yaml
