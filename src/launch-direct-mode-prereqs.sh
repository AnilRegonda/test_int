#!/bin/bash
#
#     Performs all of the necessary pre-requisites to create a Direct-mode data
#     controller. It is idempotent, provided the input does not change. Idempotency
#     is required here since Kubernetes Jobs get retried.
#
#     The script uses the 4-in-1 "unified experience for deployment", and contains
#     the cleanup logic for custom location, bootstrapper and Connected Cluster.
#
#     A single script is used for both create and delete in order to be reusable as
#     a launcher kubernetes Job, as the input variables can become a configMap.
#
#       DELETE_FLAG = false                   creates all resources
#       DELETE_FLAG = true                    deletes all resources
#
#

set -e +x pipefail

scriptPath=$(dirname "$0")
source "${scriptPath}"/launch-common.sh

# ================
# Input Validation
# ================

# Quit immediately if indirect Mode
if [ "$DATA_CONTROLLER_CONNECTIVITY" == "indirect" ]; then
  echo "$(timestamp) | INFO | Skipping Direct-Mode pre-reqs and exiting script"
  exit 0
fi
if [[ "${DELETE_FLAG}" != "true" && "${DELETE_FLAG}" != "false" ]]; then
  echo "$(timestamp) | ERROR | DELETE_FLAG is set to an invalid value"
  exit 1
fi
# Common
#
if [[ -z "${CONNECTED_CLUSTER_NAME}" ]]; then
  echo "$(timestamp) | ERROR | CONNECTED_CLUSTER_NAME is not set, required for Connected Cluster"
  exit 1
fi
if [[ -z "${CONNECTED_CLUSTER_RESOURCE_GROUP}" ]]; then
  echo "$(timestamp) | ERROR | CONNECTED_CLUSTER_RESOURCE_GROUP is not set, required for Connected Cluster"
  exit 1
fi
# Delete-only
#
if [ "${DELETE_FLAG}" == 'true' ]; then
  if [ "${CUSTOM_LOCATION_EXISTS}" == 'true' ] && [ -z "${CUSTOM_LOCATION_NAME}" ]; then
    echo "$(timestamp) | ERROR | CUSTOM_LOCATION_NAME is not set, required for Custom Location Cleanup"
    exit 1
  fi
  if [ "${ARC_DATASERVICES_EXTENSION_EXISTS}" == 'true' ] && [ -z "${ARC_DATASERVICES_EXTENSION_NAME}" ]; then
    echo "$(timestamp) | ERROR | ARC_DATASERVICES_EXTENSION_NAME is not set, required for Extension Cleanup"
    exit 1
  fi
fi
# Onboard-only
#
if [ "${DELETE_FLAG}" == 'false' ]; then
  # If KAP Pod doesn't come up in this duration, installation will abort. Connected
  # Cluster team didn't have a good workaround for this if the cert doesn't get generated
  # in ARM for KAP to consume and it hangs, so they added a timeout flag instead
  timeout_param=()
  if [[ -n "${CONNECTED_CLUSTER_ONBOARDING_TIMEOUT}" ]]; then
    timeout_param+=(--onboarding-timeout "${CONNECTED_CLUSTER_ONBOARDING_TIMEOUT}")
    echo "$(timestamp) | INFO | Arc K8s Agent install will time out in: ${CONNECTED_CLUSTER_ONBOARDING_TIMEOUT} seconds"
  fi
  if [ -z "${KUBECONFIG}" ]; then
    echo "$(timestamp) | ERROR | KUBECONFIG is not set, required for Connected Cluster"
    exit 1
  fi
  if [[ -z "${CONNECTED_CLUSTER_LOCATION}" ]]; then
    echo "$(timestamp) | ERROR | CONNECTED_CLUSTER_LOCATION is not set, required for Connected Cluster"
    exit 1
  fi
  # Connected Cluster needs Custom Location Object ID for a given AAD tenant
  custom_location_oid_param=()
  if [[ -z "${CUSTOM_LOCATION_OID}" ]]; then
    echo "$(timestamp) | ERROR | CUSTOM_LOCATION_OID is required for your AAD tenant for Arc Agent onboarding."
    exit 1
  else
    echo "$(timestamp) | INFO | Custom Location Object ID: ${CUSTOM_LOCATION_OID}"
    custom_location_oid_param+=(--custom-locations-oid "${CUSTOM_LOCATION_OID}")
  fi
  # Hidden for 4-in-1 deployment
  if [[ -z "${ARC_DATASERVICES_EXTENSION_RELEASE_TRAIN}" ]]; then
    echo "$(timestamp) | ERROR | ARC_DATASERVICES_EXTENSION_RELEASE_TRAIN is not set, required for Connected Cluster"
    exit 1
  fi
  # Hidden for 4-in-1 deployment
  if [[ -z "${ARC_DATASERVICES_EXTENSION_VERSION_TAG}" ]]; then
    echo "$(timestamp) | ERROR | ARC_DATASERVICES_EXTENSION_VERSION_TAG is not set, required for Connected Cluster"
    exit 1
  fi
fi

# Login each time - script can trigger
# after bearer timeout has expired
azure_login_spn

# ======================
# Handle delete and exit
# ======================

if [ "${DELETE_FLAG}" == 'true' ]; then
  echo "$(timestamp) | INFO | Starting destruction process"

  # Keep going despite errors during cleanup
  set +e

  # Custom Location
  if [ "$CUSTOM_LOCATION_EXISTS" == 'true' ]; then
    echo "$(timestamp) | INFO | Deleting Custom Location $CUSTOM_LOCATION_NAME"
    az customlocation delete --name "${CUSTOM_LOCATION_NAME}" \
      --resource-group "${CONNECTED_CLUSTER_RESOURCE_GROUP}" \
      --yes \
      ${VERBOSE:+--debug --verbose}
  fi

  # Bootstrapper Extension
  if [ "$ARC_DATASERVICES_EXTENSION_EXISTS" == 'true' ]; then
    echo "$(timestamp) | INFO | Deleting Bootstrapper Extension $ARC_DATASERVICES_EXTENSION_NAME"
    az k8s-extension delete --name "${ARC_DATASERVICES_EXTENSION_NAME}" \
      --cluster-type connectedClusters \
      --cluster-name "${CONNECTED_CLUSTER_NAME}" \
      --resource-group "${CONNECTED_CLUSTER_RESOURCE_GROUP}" \
      --yes \
      ${VERBOSE:+--debug --verbose}
  fi

  echo "$(timestamp) | INFO | Deleting Connected Cluster $CONNECTED_CLUSTER_NAME"
  az connectedk8s delete --name "${CONNECTED_CLUSTER_NAME}" \
    --resource-group "${CONNECTED_CLUSTER_RESOURCE_GROUP}" \
    --yes \
    ${VERBOSE:+--debug --verbose}

  # Resource Groups are left as-is for other runs.
  echo "----------------------------------------------------------------------------------"
  echo "$(timestamp) | INFO | Direct Mode Pre-req Destruction complete."
  echo "----------------------------------------------------------------------------------"
  exit 0
fi

# ======
# Create
# ======

# Resource Group creation (idempotent)
echo "$(timestamp) | INFO | Creating Resource Group $CONNECTED_CLUSTER_RESOURCE_GROUP"
az group create --resource-group "$CONNECTED_CLUSTER_RESOURCE_GROUP" \
  --location "$CONNECTED_CLUSTER_LOCATION" \
  ${VERBOSE:+--debug --verbose}

# Connected Cluster
echo "$(timestamp) | INFO | Creating Connected Cluster $CONNECTED_CLUSTER_NAME"
az connectedk8s connect --name "${CONNECTED_CLUSTER_NAME}" \
  --resource-group "${CONNECTED_CLUSTER_RESOURCE_GROUP}" \
  --location "${CONNECTED_CLUSTER_LOCATION}" \
  "${custom_location_oid_param[@]}" \
  "${timeout_param[@]}" \
  ${VERBOSE:+--debug --verbose}

# Custom Location feature
echo "$(timestamp) | INFO | Enabling Cluster-Connect and Custom-Locations"
az connectedk8s enable-features -n "${CONNECTED_CLUSTER_NAME}" \
  --resource-group "${CONNECTED_CLUSTER_RESOURCE_GROUP}" \
  --kube-config "${KUBECONFIG}" \
  --features cluster-connect custom-locations \
  "${custom_location_oid_param[@]}" \
  ${VERBOSE:+--debug --verbose}

echo "----------------------------------------------------------------------------------"
echo "$(timestamp) | INFO | Direct Mode Pre-req creation complete."
echo "----------------------------------------------------------------------------------"
exit 0
