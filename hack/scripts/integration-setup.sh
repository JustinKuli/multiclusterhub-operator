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

yq -i '.spec.relatedImages = []' "${csvPath}"

for kebabName in $(yq -o=yaml 'keys | .[]' "${imgCfgPath}"); do
    snakeName="${kebabName//-/_}"
    bigName=$(echo "${snakeName}" | tr "[:lower:]" "[:upper:]")
    snapName="${kebabName}-acm-211"

    image=$(yq '.["'"${kebabName}"'"]' "${imgCfgPath}")
    if yq -e -o=yaml '.components[] | select(.name == "'"${snapName}"'").containerImage' snapshot.json > /dev/null 2>&1; then
        echo "Using image from snapshot for ${kebabName}"
        image=$(yq -o=yaml '.components[] | select(.name == "'"${snapName}"'").containerImage' snapshot.json)
    else
        echo "Using default image for ${kebabName}"
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

cat "${csvPath}"

echo "... now what?"
