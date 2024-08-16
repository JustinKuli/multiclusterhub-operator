#!/usr/bin/env bash
set -euo pipefail

if which yq; then
    echo "Using pre-installed yq"
else
    echo "Installing yq"
    YQ_VERSION=v4.44.3
    YQ_BINARY=yq_linux_amd64
    wget https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_BINARY}.tar.gz -O - |\
    tar xz && mv ${YQ_BINARY} /usr/bin/yq
    which yq
fi

echo "${SNAPSHOT}" > snapshot.json

csvPath='../../bundle/manifests/multiclusterhub-operator.clusterserviceversion.yaml'
containerPath='.spec.install.spec.deployments[0].spec.template.spec.containers[0]'
imgCfgPath='/tmp/vol/image-config.yaml'

echo "Adding info to the manifest CSV"
yq -i '.spec.relatedImages = []' "${csvPath}"

for kebabName in $(yq -o=yaml 'keys | .[]' "${imgCfgPath}"); do
    snakeName="${kebabName//-/_}"
    bigName=$(echo "${snakeName}" | tr "[:lower:]" "[:upper:]")
    snapName="${kebabName}-acm-211"

    image=$(yq '.["'"${kebabName}"'"]' "${imgCfgPath}")
    if yq -e -o=yaml '.components[] | select(.name == "'"${snapName}"'").containerImage' snapshot.json > /dev/null 2>&1; then
        echo "  Using image from snapshot for ${kebabName}"
        image=$(yq -o=yaml '.components[] | select(.name == "'"${snapName}"'").containerImage' snapshot.json)
    else
        echo "  Using default image for ${kebabName}"
    fi

    if [[ "${kebabName}" == "multiclusterhub-operator" ]]; then
        yq -i "${containerPath}.image = \"${image}\"" "${csvPath}"
    else
        newEnv="{\"name\": \"OPERAND_IMAGE_${bigName}\", \"value\": \"${image}\"}"
        yq -i "${containerPath}.env += ${newEnv}" "${csvPath}"

        newRelatedImg="{\"name\": \"${snakeName}\", \"image\": \"${image}\"}"
        yq -i ".spec.relatedImages += ${newRelatedImg}" "${csvPath}"
    fi
done

echo "Setting up the cluster registry"
oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge
dnf -y install buildah

HOST=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
if [[ -z "${HOST}" ]]; then
    echo "registry route not present yet, waiting 15s"
    sleep 15
    HOST=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
    if [[ -z "${HOST}" ]]; then
        echo "Registry route still not present, giving up"
        exit 1
    fi
fi

echo "Building and pushing the bundle image"
buildah login -u testuser -p $(oc whoami -t) $HOST --tls-verify=false
cd ../..
image="${HOST}/openshift-marketplace/mch-bundle:0.0.1"
buildah build . -f ./bundle.Dockerfile -t "${image}" --tls-verify=false
buildah push "${image}" "docker://${image}"

echo "Setting up the CatalogSource and Subscription"

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: mch-test-registry
  namespace: openshift-marketplace
spec:
  displayName: MCH Test
  image: ${image}
  sourceType: grpc
EOF

# For possible debugging...
sleep 30
oc get packagemanifest
oc get packagemanifest multiclusterhub-operator -o yaml

oc create ns open-cluster-management

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: multiclusterhub-operator
  namespace: open-cluster-management
spec:
  channel: "stable"
  installPlanApproval: Automatic
  name: multiclusterhub-operator
  source: mch-test-registry
  sourceNamespace: openshift-marketplace
EOF

sleep 60
oc get sub.operators -A -o yaml

if oc get mch -n open-cluster-management multiclusterhub; then
    echo "MCH already present"
else
echo "Creating a default MCH"
oc apply -f - <<EOF
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec: {}
EOF
sleep 30
fi

oc get mch -n open-cluster-management multiclusterhub -o yaml

COLS='NAMESPACE:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,IMAGES:.spec.containers[0].image'
oc get pods -A -o=custom-columns=${COLS} | grep open-cluster-management

echo "Waiting 5 minutes to see what might be changing"

sleep 300
oc get pods -A -o=custom-columns=${COLS} | grep open-cluster-management
