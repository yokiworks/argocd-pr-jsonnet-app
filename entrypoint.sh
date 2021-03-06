#!/bin/bash

GITHUB_PAT=${1}
KUBECONFIG=${2}
ORG=${3}
INFRA_REPO=${4}
PR_REF=${5}
CLUSTER=${6}
DOMAIN=${7}
IMAGE=${8}
TAG=${9}

echo "<<<< Cloning infrastructure repo ${ORG}/${INFRA_REPO}"
git clone https://${GITHUB_PAT}@github.com/${ORG}/${INFRA_REPO}.git
cd infrastructure

echo ${KUBECONFIG} | base64 -d > /kubeconfig.yaml
echo ">>>> kubeconfig created"

git config --local user.name "GitHub Action"
git config --local user.email "action@github.com"
git remote set-url origin https://x-access-token:${GITHUB_PAT}@github.com/${ORG}/${INFRA_REPO}
git fetch --all

echo ">>>> Compiling manifests for"
echo "ref ${PR_REF}"
echo "cluster ${CLUSTER}"
echo "domain ${DOMAIN}"
echo "image ${IMAGE}:${TAG}"

REGEX="[a-zA-Z]+-[0-9]{1,5}"

## Deploy to staging if branch is develop, release, main or master
## Note: infrastrucure branch is using master
if [[ ${PR_REF} =~ ^refs/heads/(master|develop|release|main)$ ]]; then
  export NAMESPACE=staging
  export BRANCH=master
  git checkout master

##
# checking if this is a feature branch or release
elif [[ ${PR_REF} =~ ${REGEX} ]]; then
  ##
  # If branch does not exist create it
  export BRANCH=${PR_REF}
  git checkout ${BRANCH} || git checkout -b ${BRANCH}

  ##
  # set namespace as jira issue id extracted from branch name and make sure it is lowercase
  export NAMESPACE=$(echo ${BASH_REMATCH[0]} |  tr '[:upper:]' '[:lower:]')

else
  echo "<<<< ${PR_REF} cannot be deployed, it is not a feature branch nor a release"
  exit 0
fi

## compile manifests and add changes to git
cd jsonnet/${ORG}
CLUSTER=${CLUSTER} DOMAIN=${DOMAIN} NAMESPACE=${NAMESPACE} IMAGE=${IMAGE} TAG=${TAG} ./compile.sh
git add -A
          
## If there is nothing to commit exit without fail to continue
# this will happan if you running a deployment manually for a specific commit 
# so there will be no changes in the compiled manifests since no new docker image created
git commit -am "recompiled deployment manifests" || exit 0
git push --set-upstream origin ${BRANCH}

if [[ $(kubectl --kubeconfig=/kubeconfig.yaml -n argocd get application ${NAMESPACE}) ]]; then 
  echo ">>>> Application exist, OK!"
else
  echo ">>>> Creating Application"
fi

kubectl --kubeconfig=/kubeconfig.yaml -n argocd apply -f -<<EOF
kind: Application
apiVersion: argoproj.io/v1alpha1
metadata:
  name: ${NAMESPACE}
  namespace: argocd
spec:
  destination:
    namespace: ${NAMESPACE}
    server: 'https://kubernetes.default.svc'
  project: default
  source:
    path: jsonnet/${ORG}/clusters/${CLUSTER}/manifests
    repoURL: https://github.com/${ORG}/${INFRA_REPO}
    targetRevision: ${BRANCH}
  syncPolicy:
    automated: {}
EOF
