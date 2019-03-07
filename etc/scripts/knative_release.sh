#!/usr/bin/env bash

set -e

# This script mirrors the Knative images built by OpenShift CI to
# quay.io. It also pushes tags to GitHub for each repository in the
# release except knative-operators.
#
# For every new major or minor version, bump RELEASE_MAJOR_MINOR to
# the correct value. If doing a patch release, the script may need to
# be adjusted a bit. At a minimum, RELEASE_VERSION will need to be
# updated to not assume the patch version is 0.
#
# Also check CI_TAGS and add/remove/rename any images if they've
# changed since the last release.
#
# The definitive list of images for each repo in Knative can be found
# by looking at the bottom of the build logs for each Knative release
# promotion job at
# https://openshift-gce-devel.appspot.com/jobs/origin-ci-test/logs/.
#
# For example,
# https://openshift-gce-devel.appspot.com/builds/origin-ci-test/logs/branch-ci-openshift-knative-build-release-0.3-images/
# and then click on the most recent job for the 0.3 release branch, view the entire log, and you'll see lines like:
#
# 2019/02/19 21:41:32 Promoting tags to openshift/knative-v0.3:${component}: knative-build-controller, knative-build-creds-init, knative-build-git-init, knative-build-nop, knative-build-test-panic, knative-build-webhook
# 


RELEASE_MAJOR_MINOR="0.3"

RELEASE_VERSION="${RELEASE_MAJOR_MINOR}.0"
RELEASE_BRANCH="release-${RELEASE_MAJOR_MINOR}"
RELEASE_TAG="openshift-v${RELEASE_VERSION}"
RELEASE_DOCKER_REPO="quay.io/openshift-knative/knative-${RELEASE_VERSION}"

CI_DOCKER_REGISTRY="registry.svc.ci.openshift.org"
CI_DOCKER_ORG="openshift"
CI_DOCKER_IMAGE="knative-v${RELEASE_MAJOR_MINOR}"

CI_TAGS=$(cat <<EOF
knative-build-controller
knative-build-creds-init
knative-build-git-init
knative-build-nop
knative-build-webhook
knative-eventing-controller
knative-eventing-fanoutsidecar
knative-eventing-in-memory-channel-controller
knative-eventing-kafka
knative-eventing-webhook
knative-eventing-sources-awssqs-receive-adapter
knative-eventing-sources-cronjob-receive-adapter
knative-eventing-sources-github-receive-adapter
knative-eventing-sources-heartbeats
knative-eventing-sources-heartbeats-receiver
knative-eventing-sources-kuberneteseventsource
knative-eventing-sources-manager
knative-eventing-sources-message-dumper
knative-eventing-sources-websocketsource
knative-serving-activator
knative-serving-autoscaler
knative-serving-controller
knative-serving-queue
knative-serving-webhook
EOF
       )

function push_knative_images(){
  # First pull all the images
  for tag in ${CI_TAGS}; do
    echo "Pulling image ${CI_DOCKER_REGISTRY}/${CI_DOCKER_ORG}/${CI_DOCKER_IMAGE}:${tag}"
    docker pull ${CI_DOCKER_REGISTRY}/${CI_DOCKER_ORG}/${CI_DOCKER_IMAGE}:${tag}
  done

  # Then tag them
  for tag in ${CI_TAGS}; do
    echo "Tagging image ${RELEASE_DOCKER_REPO}:${tag}"
    docker tag ${CI_DOCKER_REGISTRY}/${CI_DOCKER_ORG}/${CI_DOCKER_IMAGE}:${tag} ${RELEASE_DOCKER_REPO}:${tag}
  done

  # Then, only if pulling and tagging were successful, push them
  for tag in ${CI_TAGS}; do
    echo "Pushing image ${RELEASE_DOCKER_REPO}:${tag}"
    docker push ${RELEASE_DOCKER_REPO}:${tag}
  done
}

function tag_knative_forks(){
  for project in build serving eventing eventing-sources; do
    echo "Tagging ${project} with ${RELEASE_TAG}"
    git clone -q -b ${RELEASE_BRANCH} git@github.com:openshift/knative-${project}.git

    pushd knative-${project} > /dev/null
    git tag -f ${RELEASE_TAG}
    git push origin ${RELEASE_TAG}
    popd > /dev/null
  done
}

function update_and_tag_repos(){
  local tmpdir=$(mktemp -d)
  echo "Using ${tmpdir} as a temporary directory for repo clones"
  pushd $tmpdir > /dev/null

  tag_knative_forks ${RELEASE_VERSION}

  echo "Tagging Documentation with ${RELEASE_TAG}"
  git clone -q git@github.com:openshift-cloud-functions/Documentation.git
  pushd Documentation
  git tag -f ${RELEASE_TAG}
  git push -f origin ${RELEASE_TAG}
  popd

  popd > /dev/null

  # Just a sanity check before we rm -rf something...
  if [[ $(echo "${tmpdir}" | grep "/tmp/tmp") ]]; then
    rm -rf "${tmpdir}"
  fi
}

echo "Releasing OpenShift Knative ${RELEASE_VERSION}"

push_knative_images

update_and_tag_repos

exit 0
