i#!/usr/bin/env bash

set +eux

BUILDER_NAMESPACE="automotive-dev-operator-system"
JUMPSTARTER_NAMESPACE="auto-jumpstarter"

if [ "$#" -ne 1 ]; then
  echo "Usage: $(basename "$0") GITHUB_PAT" >&2
  echo "  GITHUB_PAT: the GitHub Personal Access Token to use for setting up the buildspace." >&2
  exit 1
fi

# get the GitHub Personal Access Token from the command line
GIT_PAT=$1

# get the GitHub repository name from the remote URL
GIT_REMOTE_URL=$(git remote get-url origin)
GIT_REPO=${GIT_REMOTE_URL#*github.com[:/]}
GIT_REPO=${GIT_REPO%.git}

# some endpoints
CONSOLE_URL=$(oc whoami --show-console)
BASE_URL=${CONSOLE_URL#https://console-openshift-console.}

# NAMESPACE normalization for use in kubernetes
NAMESPACE=buildspace-$(echo "$GIT_REPO" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-zA-Z0-9-]/-/g; s/-\+/-/g; s/^-//; s/-$//' | cut -c1-63)

echo "User Setup for NAMESPACE: $NAMESPACE"

if ! oc get namespace "$NAMESPACE" &>/dev/null; then
  echo "Error: Namespace $NAMESPACE does not exist. Please ask an administrator to run buildspace-admin.sh first." >&2
  exit 1
fi

# create configmaps
oc create configmap jumpstarter-devspaces-config -n $NAMESPACE \
--from-literal=JUMPSTARTER_GRPC_ENDPOINT="grpc.$JUMPSTARTER_NAMESPACE.$BASE_URL" \
--from-literal=JUMPSTARTER_LOGIN_ENDPOINT="login.$JUMPSTARTER_NAMESPACE.$BASE_URL" \
--from-literal=JUMPSTARTER_NAMESPACE=$JUMPSTARTER_NAMESPACE

oc create configmap builder-devspaces-config -n $NAMESPACE \
  --from-literal=CAIB_SERVER="https://ado-build-api-$BUILDER_NAMESPACE.$BASE_URL" \
  --from-literal=BUILDER_NAMESPACE=$BUILDER_NAMESPACE

# prepare for PAC setup
PAC_ENDPOINT="https://pipelines-as-code-controller-openshift-pipelines.$BASE_URL"

# Create the webhook secret and create the webhook config secret
WEBHOOK_SECRET=$(openssl rand -hex 20)

if oc get secret github-webhook-config -n "$NAMESPACE" &>/dev/null; then
  oc delete secret github-webhook-config -n "$NAMESPACE"
  echo "Waiting for secret github-webhook-config to be deleted..."
  sleep 10
fi

oc -n $NAMESPACE create secret generic github-webhook-config \
  --from-literal provider.token="$GIT_PAT" \
  --from-literal webhook.secret="$WEBHOOK_SECRET"

# PAC endpoint setup

# create the webhook
HOOK_EXISTS=$(curl -sS \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GIT_PAT}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${GIT_REPO}/hooks" \
  | jq -e --arg url "$PAC_ENDPOINT" '.[] | select(.config.url == $url)')

if [[ -n "$HOOK_EXISTS" ]]; then
  echo "Webhook already exists, deleting it"
  HOOK_ID=$(echo "$HOOK_EXISTS" | jq -r '.id')
  curl -sS -X DELETE \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GIT_PAT}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${GIT_REPO}/hooks/${HOOK_ID}"
fi

echo "Creating webhook..."

curl -sS -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GIT_PAT}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${GIT_REPO}/hooks" \
  -d @- <<EOF
{
  "name": "web",
  "active": true,
  "events": ["push", "pull_request", "issue_comment", "commit_comment"],
  "config": {
    "url": "${PAC_ENDPOINT}",
    "content_type": "json",
    "insecure_ssl": "0",
    "secret": "${WEBHOOK_SECRET}"
  }
}
EOF

# create the Repository CR
REPOSITORY_NAME=$NAMESPACE-pac

if oc get repository $REPOSITORY_NAME -n "$NAMESPACE" &>/dev/null; then
  oc delete repository $REPOSITORY_NAME -n "$NAMESPACE"
  echo "Waiting for repository $REPOSITORY_NAME to be deleted..."
  sleep 10
fi

oc create -f - <<EOF
apiVersion: "pipelinesascode.tekton.dev/v1alpha1"
kind: Repository
metadata:
  name: $REPOSITORY_NAME
  namespace: ${NAMESPACE}
spec:
  url: "https://github.com/${GIT_REPO}"
  git_provider:
    secret:
      name: "github-webhook-config"
      key: "provider.token"
    webhook_secret:
      name: "github-webhook-config"
      key: "webhook.secret"
EOF

echo "User setup completed successfully."
