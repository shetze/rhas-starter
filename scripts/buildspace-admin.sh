#!/usr/bin/env bash

set +eux

if [ "$#" -ne 1 ]; then
  echo "Usage: $(basename "$0") NAMESPACE_NAME" >&2
  echo "  NAMESPACE_NAME: The name of the namespace to create (e.g. buildspace-shetze-rhas-starter)" >&2
  exit 1
fi

NAMESPACE=$1

echo "Admin Setup for NAMESPACE: $NAMESPACE"

if oc get namespace "$NAMESPACE" &>/dev/null; then
  echo "Namespace $NAMESPACE already exists"
else
  oc create -f - <<-EOF
kind: Namespace
apiVersion: v1
metadata:
  name: $NAMESPACE
  labels:
    app.kubernetes.io/part-of: rhas
EOF
fi

echo "Waiting for pipeline serviceaccount in $NAMESPACE..."
until oc get serviceaccounts -n "$NAMESPACE" 2>/dev/null | grep -q pipeline; do
    sleep 10
done

# add cluster roles to the pipeline serviceaccount
oc adm policy add-cluster-role-to-user pipelines-access-role "system:serviceaccount:$NAMESPACE:pipeline" -n $NAMESPACE
oc adm policy add-cluster-role-to-user jumpstarter-access-role "system:serviceaccount:$NAMESPACE:pipeline" -n $NAMESPACE

# allow platform users to view & edit the buildspace namespace
oc adm policy add-role-to-group view platform-users -n $NAMESPACE
oc adm policy add-role-to-group edit platform-users -n $NAMESPACE

# create the auto-exporters namespace if it doesn't exist
if ! oc get namespace auto-exporters &>/dev/null; then
  echo "Creating auto-exporters namespace..."
  oc create namespace auto-exporters
fi

# apply ALL exporter configurations seamlessly
echo "Applying qemu-exporter configurations to auto-exporters namespace..."
oc apply -f exporters/qemu-exporter/ -n auto-exporters

# image pull rights for the exporter in the new namespace
echo "Granting image pull rights to the qemu-exporter..."
oc policy add-role-to-user system:image-puller \
	system:serviceaccount:auto-exporters:qemu-exporter \
	-n automotive-dev-operator-system

echo "Admin setup completed successfully."
