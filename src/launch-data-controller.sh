#!/bin/bash
#
#     Creates/deletes data controller in both modes - Direct and Indirect -
#     the behavior is driven by DATA_CONTROLLER_CONNECTIVITY.
#
#     A single script is used for both create and delete to promote
#     idempotency in Kubernetes Job.
#
#       DELETE_FLAG = false                   creates controller
#       DELETE_FLAG = true                    deletes controller
#

set -e +x pipefail

scriptPath=$(dirname "$0")
source "${scriptPath}"/launch-common.sh

# =============================
# Input Validation for behavior
# =============================

# Common
if [[ "${DELETE_FLAG}" != "true" && "${DELETE_FLAG}" != "false" ]]; then
  echo "$(timestamp) | ERROR | DELETE_FLAG is set to an invalid value"
  exit 1
fi
if [[ -z "${DATA_CONTROLLER_CONNECTIVITY}" ]]; then
  echo "$(timestamp) | ERROR | DATA_CONTROLLER_CONNECTIVITY must be set for Data Controller"
  exit 1
fi
if [[ -z "${DATA_CONTROLLER_NAME}" ]]; then
  echo "$(timestamp) | ERROR | DATA_CONTROLLER_NAME must be set for Data Controller"
  exit 1
fi
if [[ -z "${CONTROLLER_PROFILE}" ]]; then
  echo "$(timestamp) | ERROR | CONTROLLER_PROFILE must be set for Data Controller"
  exit 1
fi
if [[ -z "${DEPLOYMENT_INFRASTRUCTURE}" ]]; then
  echo "$(timestamp) | ERROR | DEPLOYMENT_INFRASTRUCTURE must be set for Data Controller"
  exit 1
fi
if [[ -z "${DATA_CONTROLLER_SUBSCRIPTION_ID}" ]]; then
  echo "$(timestamp) | ERROR | DATA_CONTROLLER_SUBSCRIPTION_ID must be set for Data Controller"
  exit 1
fi
if [[ -z "${DATA_CONTROLLER_RESOURCE_GROUP}" ]]; then
  echo "$(timestamp) | ERROR | DATA_CONTROLLER_RESOURCE_GROUP must be set for Data Controller"
  exit 1
fi
if [[ -z "${DATA_CONTROLLER_LOCATION}" ]]; then
  echo "$(timestamp) | ERROR | DATA_CONTROLLER_LOCATION must be set for Data Controller"
  exit 1
fi

# Indirect
if [[ "${DATA_CONTROLLER_CONNECTIVITY}" == "indirect" ]]; then
  if [[ -z "${DATA_CONTROLLER_NAMESPACE}" ]]; then
    echo "$(timestamp) | ERROR | DATA_CONTROLLER_NAMESPACE must be set for Indirect Mode Data Controller"
    exit 1
  fi
fi

# Direct
if [[ "${DATA_CONTROLLER_CONNECTIVITY}" == "direct" ]]; then
  if [[ -z "${CONNECTED_CLUSTER_NAME}" ]]; then
    echo "$(timestamp) | ERROR | CONNECTED_CLUSTER_NAME must be set for Direct Mode Data Controller"
    exit 1
  fi
  if [[ -z "${CUSTOM_LOCATION_NAME}" ]]; then
    echo "$(timestamp) | ERROR | CUSTOM_LOCATION_NAME must be set for Direct Mode Data Controller"
    exit 1
  fi
fi

# Login each time - script can trigger
# after bearer timeout has expired
azure_login_spn

# mode_param to contain mutually exclusive args for "direct" and "indirect"
#
mode_param=()

# ======================
# Handle delete and exit
# ======================

if [ "${DELETE_FLAG}" == 'true' ]; then
  echo "$(timestamp) | INFO | Starting destruction process"

  # Keep going despite errors during cleanup
  set +e

  if [ "$DATA_CONTROLLER_CONNECTIVITY" == "indirect" ]; then
    mode_param+=(--k8s-namespace "${DATA_CONTROLLER_NAMESPACE}")
    mode_param+=(--force)
    mode_param+=(--use-k8s)
  elif [ "$DATA_CONTROLLER_CONNECTIVITY" == "direct" ]; then
    mode_param+=(--subscription "${DATA_CONTROLLER_SUBSCRIPTION_ID}")
    mode_param+=(--resource-group "${DATA_CONTROLLER_RESOURCE_GROUP}")
  fi

  echo "$(timestamp) | INFO | Deleting Data Controller ${DATA_CONTROLLER_NAME}"
  az arcdata dc delete \
    --name "${DATA_CONTROLLER_NAME}" \
    --yes \
    "${mode_param[@]}" \
    ${VERBOSE:+--debug --verbose}

  echo "----------------------------------------------------------------------------------"
  echo "$(timestamp) | INFO | Data Controller destruction complete."
  echo "----------------------------------------------------------------------------------"
  exit 0
fi

# ======
# Create
# ======

echo "$(timestamp) | INFO | Creating Data Controller ${DATA_CONTROLLER_NAME} in mode: ${DATA_CONTROLLER_CONNECTIVITY}"
# Controller profile generation and patch
az arcdata dc config init -s "${CONTROLLER_PROFILE}" --path "${scriptPath}"/custom --force
az arcdata dc config patch --path "${scriptPath}"/custom/control.json --patch-file "${scriptPath}"/config/patch.json
az arcdata dc config replace --path "${scriptPath}"/custom/control.json --json-values ".spec.infrastructure=${DEPLOYMENT_INFRASTRUCTURE}"

if [ "$DATA_CONTROLLER_CONNECTIVITY" == "indirect" ]; then
  # Currently, custom monitoring certs are only supported in Indirect Mode
  MONITORING_CERT_DIR=$(mktemp -d)
  "${scriptPath}"/create-monitoring-tls-files.sh "${DATA_CONTROLLER_NAMESPACE}" "${MONITORING_CERT_DIR}"
  mode_param+=(--logs-ui-private-key-file "${MONITORING_CERT_DIR}/logsui-key.pem")
  mode_param+=(--logs-ui-public-key-file "${MONITORING_CERT_DIR}/logsui-cert.pem")
  mode_param+=(--metrics-ui-private-key-file "${MONITORING_CERT_DIR}/metricsui-key.pem")
  mode_param+=(--metrics-ui-public-key-file "${MONITORING_CERT_DIR}/metricsui-cert.pem")
  mode_param+=(--k8s-namespace "${DATA_CONTROLLER_NAMESPACE}")
  mode_param+=(--use-k8s)
elif [ "$DATA_CONTROLLER_CONNECTIVITY" == "direct" ]; then
  mode_param+=(--cluster-name "${CONNECTED_CLUSTER_NAME}")
  mode_param+=(--custom-location "${CUSTOM_LOCATION_NAME}")
  mode_param+=(--auto-upload-metrics true)
  mode_param+=(--auto-upload-logs true)
  # Resource Group creation (idempotent)
  echo "$(timestamp) | INFO | Creating Resource Group ${DATA_CONTROLLER_RESOURCE_GROUP}"
  az group create --resource-group "$DATA_CONTROLLER_RESOURCE_GROUP" \
    --location "$DATA_CONTROLLER_LOCATION" \
    ${VERBOSE:+--debug --verbose}
fi

az arcdata dc create --path "${scriptPath}"/custom \
  --name "${DATA_CONTROLLER_NAME}" \
  --subscription "${DATA_CONTROLLER_SUBSCRIPTION_ID}" \
  --resource-group "${DATA_CONTROLLER_RESOURCE_GROUP}" \
  --location "${DATA_CONTROLLER_LOCATION}" \
  --connectivity-mode "${DATA_CONTROLLER_CONNECTIVITY}" \
  "${mode_param[@]}" \
  ${VERBOSE:+--debug --verbose}

rm -rf "${MONITORING_CERT_DIR}"

echo "----------------------------------------------------------------------------------"
echo "$(timestamp) | INFO | Data Controller creation complete."
echo "----------------------------------------------------------------------------------"
exit 0