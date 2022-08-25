#
#
#     This script contains common functions, meant to be sourced inside the
#     launcher container's entrypoint. It assumes access to utilities such as:
#       - az cli
#       - kubectl
#
#     And does not assume access to host machine specific tooling such as:
#       - docker cli
#
#

# Log into Azure as Service Principal, if not already logged in
# Sets context to Azure Subscription from environment variable
#
azure_login_spn() {
  if [ -z "$(az account show)" ]; then
    echo "$(timestamp) | INFO | Logging into Azure:"

    az login --service-principal \
      -u "${SPN_CLIENT_ID}" \
      -p "${SPN_CLIENT_SECRET}" \
      --tenant "${SPN_TENANT_ID}" \
      --query "[].{\"Available Subscriptions\":name}" \
      --output table

    echo "$(timestamp) | INFO | Setting subscription to: ${SUBSCRIPTION_ID}"
    az account set --subscription "${SUBSCRIPTION_ID}"
  else
    echo "$(timestamp) | INFO | Already logged into Azure."
  fi

  # Print current context
  #
  AZ_CURRENT_ACCOUNT=$(az account show --query "name" --output tsv)
  echo "$(timestamp) | INFO | Current subscription assigned: $AZ_CURRENT_ACCOUNT"
}

# Removes ARM and K8s components from Cluster based
# on existing cluster metadata
#
get_and_clean_resources() {
  get_resources
  clean_resources
}

# Cleanup old state, should be run after get_arcdata
# The script depends on using environment variables
# for execution
#
clean_resources() {
  echo "=================================================================================="
  echo "$(timestamp) | INFO | Cleaning up resources"
  echo "=================================================================================="
  # Custom Resource
  if [ "${DATA_CONTROLLER_NAMESPACE_EXISTS}" == "true" ]; then
    echo "$(timestamp) | INFO | Cleaning up Custom Resources in namespace: ${DATA_CONTROLLER_NAMESPACE}"
    "${scriptPath}"/launch-data-custom-resource-cleanup.sh
  fi
  # Controller
  if [ "${DATA_CONTROLLER_CR_EXISTS}" == "true" ] ||
    [ "${DATA_CONTROLLER_ARM_EXISTS}" == "true" ]; then
    echo "$(timestamp) | INFO | Cleaning up Data Controller: ${DATA_CONTROLLER_NAME} in Connectivity Mode: ${DATA_CONTROLLER_CONNECTIVITY}"
    DELETE_FLAG=true \
      "${scriptPath}"/launch-data-controller.sh
  fi
  # Connected Cluster
  if [ "${CONNECTED_CLUSTER_CR_EXISTS}" == "true" ] ||
    [ "${CONNECTED_CLUSTER_ARM_EXISTS}" == "true" ]; then
    echo "$(timestamp) | INFO | Cleaning up Connected Cluster: ${CONNECTED_CLUSTER_NAME}"
    DELETE_FLAG=true \
      DATA_CONTROLLER_CONNECTIVITY="direct" \
      "${scriptPath}"/launch-direct-mode-prereqs.sh
  fi
  # Kubernetes resources
  echo "$(timestamp) | INFO | Cleaning up all residual Kubernetes resources"
  "${scriptPath}"/launch-kubernetes-cleanup.sh
  echo "=================================================================================="
  echo "$(timestamp) | INFO | Resource cleanup complete."
  echo "=================================================================================="
}

# Captures debug logs using az arcdata, intended
# to be run after each logical phase of ci; e.g.
#
#   debuglogs_arcdata "setup-complete"
#   debuglogs_arcdata "test-complete"
#
# Example of captured subdirectory:
#
#   /launcher/debuglogs/setup-complete-20220813-162842
#   /launcher/debuglogs/test-complete-20220813-164000
#
debuglogs_arcdata() {
  if [ $# -eq 1 ]; then
    export PHASE=$1
  else
    export PHASE="default"
  fi

  export LOGS_SUBFOLDER="${scriptPath}/debuglogs/arcdata/${PHASE}-$(date +%Y%m%d-%H%M%S)"
  echo "$(timestamp) | INFO | Copying logs from ${DATA_CONTROLLER_NAMESPACE} namespace to ${LOGS_SUBFOLDER}"
  mkdir -p "${LOGS_SUBFOLDER}"

  # Skip compression since we will compress for the final upload
  # This makes it easier for user-facing drill down; e.g. ADO.
  #
  az arcdata dc debug copy-logs \
    --k8s-namespace "${DATA_CONTROLLER_NAMESPACE}" \
    --target-folder "${LOGS_SUBFOLDER}" \
    --skip-compress \
    --use-k8s \
    --timeout 2400
  ${VERBOSE:+--debug --verbose}

  echo "=================================================================================="
  echo "$(timestamp) | INFO | Captured Arc data logs from ${DATA_CONTROLLER_NAMESPACE} namespace."
  echo "=================================================================================="
}

# Central healthcheck for resources - keeping this in one place allows us to
# reference it across the board, specially for cleanup. Exported variables are
# used for clean_resources.
#
get_resources() {
  echo "=================================================================================="
  echo "$(timestamp) | INFO | Resource check"
  echo "=================================================================================="
  #
  #    Launcher --> K8s (CR metadata) -> ARM (Resource metadata) -> Cleanup: K8s + ARM
  #
  # We are starting here in a potentially "brownfield" cluster containing Arc + Arc Data
  # resources. We do not know the original variables, and need to use Kubernetes as the
  # source of truth to query our way up to ARM, then perform cleanup. Having this logic
  # robustly implemented allows us to confidently test in Customer, Partner and dev envs.
  echo "----------------------------------------------------------------------------------"
  echo "$(timestamp) | INFO | Querying Kubernetes:"
  echo "----------------------------------------------------------------------------------"
  # Reset previous state based on prefix match - we need to ensure any healthcheck variables
  # follow this naming pattern to reset every time. We should not need to add much further
  # to this list as the APIs are GA.
  #
  unset $(compgen -v | grep "ARC_DATASERVICES_EXTENSION_")
  unset $(compgen -v | grep "CONNECTED_CLUSTER_")
  unset $(compgen -v | grep "CUSTOM_LOCATION_")
  unset $(compgen -v | grep "DATA_CONTROLLER_")

  # 1.CONNECTED_CLUSTER:
  #
  #     - Namespace: azure-arc (constant)
  #     - CRD: connectedclusters.arc.azure.com (constant)
  #     - CR: clustermetadata (constant)
  #     - # of resources: 1 or 0
  #
  CONNECTED_CLUSTER_CRD_QUERY=$(kubectl get crd connectedclusters.arc.azure.com --ignore-not-found=true)
  export CONNECTED_CLUSTER_CRD_EXISTS=$(true_if_nonempty "${CONNECTED_CLUSTER_CRD_QUERY}")
  if [ "${CONNECTED_CLUSTER_CRD_EXISTS}" == 'true' ]; then
    CONNECTED_CLUSTER_CR_QUERY=$(kubectl get connectedclusters.arc.azure.com clustermetadata -n azure-arc --ignore-not-found=true -o yaml)
    export CONNECTED_CLUSTER_CR_EXISTS=$(true_if_nonempty "${CONNECTED_CLUSTER_CR_QUERY}")
    if [ "${CONNECTED_CLUSTER_CR_EXISTS}" == 'true' ]; then
      CONNECTED_CLUSTER_ARM_RESOURCE_ID=$(echo "${CONNECTED_CLUSTER_CR_QUERY}" | yq .spec.azureResourceId)
      # /subscriptions/${CONNECTED_CLUSTER_SUBSCRIPTION_ID}/resourceGroups/${CONNECTED_CLUSTER_RESOURCE_GROUP}/providers/Microsoft.Kubernetes/ConnectedClusters/${CONNECTED_CLUSTER_NAME}
      # Split on "/"
      CONNECTED_CLUSTER_ARM_RESOURCE_ID_ARRAY=(${CONNECTED_CLUSTER_ARM_RESOURCE_ID//// })
      export CONNECTED_CLUSTER_SUBSCRIPTION_ID=${CONNECTED_CLUSTER_ARM_RESOURCE_ID_ARRAY[1]}
      export CONNECTED_CLUSTER_RESOURCE_GROUP=${CONNECTED_CLUSTER_ARM_RESOURCE_ID_ARRAY[3]}
      export CONNECTED_CLUSTER_NAME=${CONNECTED_CLUSTER_ARM_RESOURCE_ID_ARRAY[7]}
    fi
  fi

  # 2.DATA_CONTROLLER:
  #
  #     - Namespace: unknown
  #     - CRD: datacontrollers.arcdata.microsoft.com (constant)
  #     - CR: unknown
  #     - # of resources: N (current implementation assumes 1 or 0)
  #
  DATA_CONTROLLER_CRD_QUERY=$(kubectl get crd datacontrollers.arcdata.microsoft.com --ignore-not-found=true)
  export DATA_CONTROLLER_CRD_EXISTS=$(true_if_nonempty "${DATA_CONTROLLER_CRD_QUERY}")
  if [ "${DATA_CONTROLLER_CRD_EXISTS}" == 'true' ]; then
    DATA_CONTROLLER_CR_QUERY=$(kubectl get datacontrollers.arcdata.microsoft.com -A --ignore-not-found=true -o yaml)
    export DATA_CONTROLLER_CR_EXISTS=$(true_if_nonempty "${DATA_CONTROLLER_CR_QUERY}")
    if [ "${DATA_CONTROLLER_CR_EXISTS}" == 'true' ]; then
      DATA_CONTROLLER_CR_ARRAY=$(echo "${DATA_CONTROLLER_CR_QUERY}" | yq .items)
      # TODO: handle returning array instead of [0] if multiple Controllers are preseent across many namespaces
      export DATA_CONTROLLER_NAME=$(echo "${DATA_CONTROLLER_CR_ARRAY}" | yq .[0].metadata.name)
      export DATA_CONTROLLER_NAMESPACE=$(echo "${DATA_CONTROLLER_CR_ARRAY}" | yq .[0].metadata.namespace)
      export DATA_CONTROLLER_CONNECTIVITY=$(echo "${DATA_CONTROLLER_CR_ARRAY}" | yq .[0].spec.settings.azure.connectionMode)
      export DATA_CONTROLLER_SUBSCRIPTION_ID=$(echo "${DATA_CONTROLLER_CR_ARRAY}" | yq .[0].spec.settings.azure.subscription)
      export DATA_CONTROLLER_RESOURCE_GROUP=$(echo "${DATA_CONTROLLER_CR_ARRAY}" | yq .[0].spec.settings.azure.resourceGroup)
      export DATA_CONTROLLER_LOCATION=$(echo "${DATA_CONTROLLER_CR_ARRAY}" | yq .[0].spec.settings.azure.location)
    fi
  fi

  echo "$(timestamp) | INFO | - CONNECTED_CLUSTER_CRD_EXISTS? ${CONNECTED_CLUSTER_CRD_EXISTS}"
  if [ "${CONNECTED_CLUSTER_CRD_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |  - CONNECTED_CLUSTER_CR_EXISTS? ${CONNECTED_CLUSTER_CR_EXISTS}"; fi
  if [ "${CONNECTED_CLUSTER_CR_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |    - CONNECTED_CLUSTER_NAME: ${CONNECTED_CLUSTER_NAME}"; fi
  if [ "${CONNECTED_CLUSTER_CR_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |    - CONNECTED_CLUSTER_SUBSCRIPTION_ID: ${CONNECTED_CLUSTER_SUBSCRIPTION_ID}"; fi
  if [ "${CONNECTED_CLUSTER_CR_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |    - CONNECTED_CLUSTER_RESOURCE_GROUP: ${CONNECTED_CLUSTER_RESOURCE_GROUP}"; fi
  echo "$(timestamp) | INFO | - DATA_CONTROLLER_CRD_EXISTS? ${DATA_CONTROLLER_CRD_EXISTS}"
  if [ "${DATA_CONTROLLER_CRD_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |  - DATA_CONTROLLER_CR_EXISTS? ${DATA_CONTROLLER_CR_EXISTS}"; fi
  if [ "${DATA_CONTROLLER_CR_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |    - DATA_CONTROLLER_NAME: ${DATA_CONTROLLER_NAME}"; fi
  if [ "${DATA_CONTROLLER_CR_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |    - DATA_CONTROLLER_NAMESPACE: ${DATA_CONTROLLER_NAMESPACE}"; fi
  if [ "${DATA_CONTROLLER_CR_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |    - DATA_CONTROLLER_CONNECTIVITY: ${DATA_CONTROLLER_CONNECTIVITY}"; fi
  if [ "${DATA_CONTROLLER_CR_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |    - DATA_CONTROLLER_SUBSCRIPTION_ID: ${DATA_CONTROLLER_SUBSCRIPTION_ID}"; fi
  if [ "${DATA_CONTROLLER_CR_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |    - DATA_CONTROLLER_RESOURCE_GROUP: ${DATA_CONTROLLER_RESOURCE_GROUP}"; fi
  if [ "${DATA_CONTROLLER_CR_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |    - DATA_CONTROLLER_LOCATION: ${DATA_CONTROLLER_LOCATION}"; fi

  echo "----------------------------------------------------------------------------------"
  echo "$(timestamp) | INFO | Querying ARM:"
  echo "----------------------------------------------------------------------------------"

  # ARM Hierarchy
  # .
  # ├── 1. Resource Group - Connected Cluster
  # |    └── 2. Connected Cluster
  # |        ├── 3. Bootstrapper Extension
  # |        └── 4. Custom Location
  # └----------- 5. Resource Group - Data Controller
  #              └── 6. Data Controller

  # 1. Resource Groups
  CONNECTED_CLUSTER_RESOURCE_GROUP_ARM_QUERY=$(az group list | jq -r ".[] | select(.name==\"$CONNECTED_CLUSTER_RESOURCE_GROUP\") |.name")
  export CONNECTED_CLUSTER_RESOURCE_GROUP_EXISTS=$(true_if_nonempty "${CONNECTED_CLUSTER_RESOURCE_GROUP_ARM_QUERY}")
  DATA_CONTROLLER_RESOURCE_GROUP_ARM_QUERY=$(az group list | jq -r ".[] | select(.name==\"$DATA_CONTROLLER_RESOURCE_GROUP\") |.name")
  export DATA_CONTROLLER_RESOURCE_GROUP_EXISTS=$(true_if_nonempty "${DATA_CONTROLLER_RESOURCE_GROUP_ARM_QUERY}")
  # 2. Connected Cluster
  if [ "${CONNECTED_CLUSTER_RESOURCE_GROUP_EXISTS}" == 'true' ] && [ "${CONNECTED_CLUSTER_CR_EXISTS}" == 'true' ]; then
    CONNECTED_CLUSTER_ARM_QUERY=$(az resource list --name "$CONNECTED_CLUSTER_NAME" --resource-group "$CONNECTED_CLUSTER_RESOURCE_GROUP" --query "[?contains(type,'Microsoft.Kubernetes/connectedClusters')]" --output json)
    export CONNECTED_CLUSTER_ARM_EXISTS=$(true_if_nonempty "${CONNECTED_CLUSTER_ARM_QUERY}")
    if [ "${CONNECTED_CLUSTER_ARM_EXISTS}" == 'true' ]; then
      export CONNECTED_CLUSTER_LOCATION=$(echo $CONNECTED_CLUSTER_ARM_QUERY | jq -r .[0].location)
      # 3. Bootstrapper Extension
      ARC_DATASERVICES_EXTENSION_ARM_QUERY=$(az k8s-extension list --cluster-name "$CONNECTED_CLUSTER_NAME" --resource-group "$CONNECTED_CLUSTER_RESOURCE_GROUP" --cluster-type connectedclusters | jq -r ".[] | select(.extensionType==\"microsoft.arcdataservices\")")
      export ARC_DATASERVICES_EXTENSION_EXISTS=$(true_if_nonempty "${ARC_DATASERVICES_EXTENSION_ARM_QUERY}")
      if [ "${ARC_DATASERVICES_EXTENSION_EXISTS}" == 'true' ]; then
        export ARC_DATASERVICES_EXTENSION_NAME=$(echo "${ARC_DATASERVICES_EXTENSION_ARM_QUERY}" | jq -r .name)
        export ARC_DATASERVICES_EXTENSION_VERSION_TAG=$(echo "${ARC_DATASERVICES_EXTENSION_ARM_QUERY}" | jq -r .version)
        export ARC_DATASERVICES_EXTENSION_RELEASE_TRAIN=$(echo "${ARC_DATASERVICES_EXTENSION_ARM_QUERY}" | jq -r .releaseTrain)
        export ARC_DATASERVICES_EXTENSION_RELEASE_NAMESPACE=$(echo "${ARC_DATASERVICES_EXTENSION_ARM_QUERY}" | jq -r .scope.cluster.releaseNamespace)
        export ARC_DATASERVICES_EXTENSION_RELEASE_NAMESPACE_EXISTS=$(true_if_nonempty "${ARC_DATASERVICES_EXTENSION_RELEASE_NAMESPACE}")
        # Query back Kubernetes to see if namespace is actually present (can be there in absence of Data Controller via Bootstrapper)
        if [ "${ARC_DATASERVICES_EXTENSION_RELEASE_NAMESPACE_EXISTS}" == 'true' ]; then
          DATA_CONTROLLER_NAMESPACE_QUERY=$(kubectl get namespace ${ARC_DATASERVICES_EXTENSION_RELEASE_NAMESPACE} -o json --ignore-not-found=true)
          export DATA_CONTROLLER_NAMESPACE_EXISTS=$(true_if_nonempty "${DATA_CONTROLLER_NAMESPACE_QUERY}")
          if [ "${DATA_CONTROLLER_NAMESPACE_EXISTS}" == 'true' ]; then
            export DATA_CONTROLLER_NAMESPACE=$(echo "${DATA_CONTROLLER_NAMESPACE_QUERY}" | jq -r .metadata.name)
          fi
        fi
      fi
      # 4. Custom Location
      CUSTOM_LOCATION_ARM_QUERY=$(az customlocation list -g "${CONNECTED_CLUSTER_RESOURCE_GROUP}" | jq -r ".[]|select(.hostResourceId | endswith(\"${CONNECTED_CLUSTER_NAME}\"))")
      export CUSTOM_LOCATION_EXISTS=$(true_if_nonempty "${CUSTOM_LOCATION_ARM_QUERY}")
      if [ "${CUSTOM_LOCATION_EXISTS}" == 'true' ]; then
        export CUSTOM_LOCATION_NAME=$(echo "${CUSTOM_LOCATION_ARM_QUERY}" | jq -r .name)
      fi
      # 5. Data Controller
      if [ "${ARC_DATASERVICES_EXTENSION_EXISTS}" == 'true' ] && [ "${CUSTOM_LOCATION_EXISTS}" == 'true' ] && [ "${DATA_CONTROLLER_RESOURCE_GROUP_EXISTS}" == 'true' ] && [ "${DATA_CONTROLLER_CR_EXISTS}" == 'true' ]; then
        DATA_CONTROLLER_ARM_QUERY=$(az resource list --name "$DATA_CONTROLLER_NAME" --resource-group "$DATA_CONTROLLER_RESOURCE_GROUP" --query "[?contains(type,'Microsoft.AzureArcData/DataControllers')]" --output json)
        export DATA_CONTROLLER_ARM_EXISTS=$(true_if_nonempty "${DATA_CONTROLLER_ARM_QUERY}")
      fi
    fi
  fi

  if [ "${CONNECTED_CLUSTER_CR_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO | - CONNECTED_CLUSTER_RESOURCE_GROUP_EXISTS? ${CONNECTED_CLUSTER_RESOURCE_GROUP_EXISTS}"; fi
  if [ "${DATA_CONTROLLER_CR_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO | - DATA_CONTROLLER_RESOURCE_GROUP_EXISTS? ${DATA_CONTROLLER_RESOURCE_GROUP_EXISTS}"; fi
  if [ "${CONNECTED_CLUSTER_RESOURCE_GROUP_EXISTS}" == 'true' ] && [ "${CONNECTED_CLUSTER_CR_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |  - CONNECTED_CLUSTER_ARM_EXISTS? ${CONNECTED_CLUSTER_ARM_EXISTS}"; fi
  if [ "${CONNECTED_CLUSTER_ARM_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |    - CONNECTED_CLUSTER_LOCATION: ${CONNECTED_CLUSTER_LOCATION}"; fi
  if [ "${CONNECTED_CLUSTER_ARM_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |    - ARC_DATASERVICES_EXTENSION_EXISTS: ${ARC_DATASERVICES_EXTENSION_EXISTS}"; fi
  if [ "${ARC_DATASERVICES_EXTENSION_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |     - ARC_DATASERVICES_EXTENSION_NAME: ${ARC_DATASERVICES_EXTENSION_NAME}"; fi
  if [ "${ARC_DATASERVICES_EXTENSION_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |     - ARC_DATASERVICES_EXTENSION_VERSION_TAG: ${ARC_DATASERVICES_EXTENSION_VERSION_TAG}"; fi
  if [ "${ARC_DATASERVICES_EXTENSION_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |     - ARC_DATASERVICES_EXTENSION_RELEASE_TRAIN: ${ARC_DATASERVICES_EXTENSION_RELEASE_TRAIN}"; fi
  if [ "${ARC_DATASERVICES_EXTENSION_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |     - ARC_DATASERVICES_EXTENSION_RELEASE_NAMESPACE: ${ARC_DATASERVICES_EXTENSION_RELEASE_NAMESPACE}"; fi
  if [ "${ARC_DATASERVICES_EXTENSION_RELEASE_NAMESPACE_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |      - DATA_CONTROLLER_NAMESPACE_EXISTS: ${DATA_CONTROLLER_NAMESPACE_EXISTS}"; fi
  if [ "${DATA_CONTROLLER_NAMESPACE_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |       - DATA_CONTROLLER_NAMESPACE: ${DATA_CONTROLLER_NAMESPACE}"; fi
  if [ "${CONNECTED_CLUSTER_ARM_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |    - CUSTOM_LOCATION_EXISTS: ${CUSTOM_LOCATION_EXISTS}"; fi
  if [ "${CUSTOM_LOCATION_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |     - CUSTOM_LOCATION_NAME: ${CUSTOM_LOCATION_NAME}"; fi
  if [ "${ARC_DATASERVICES_EXTENSION_EXISTS}" == 'true' ] && [ "${CUSTOM_LOCATION_EXISTS}" == 'true' ] && [ "${DATA_CONTROLLER_RESOURCE_GROUP_EXISTS}" == 'true' ] && [ "${DATA_CONTROLLER_CR_EXISTS}" == 'true' ]; then echo "$(timestamp) | INFO |      - DATA_CONTROLLER_ARM_EXISTS? ${DATA_CONTROLLER_ARM_EXISTS}"; fi

  # Validate SUBSCRIPTION_ID, RESOURCE_GROUP, LOCATION against acquired state
  #
  #   - Currently due to 4-in-1 - we assume Connected Cluster and Data Controller
  #     is in the same resource group, subscription and location.
  #   - Therefore, we quit if these 3 don't match acquired state, because we can't
  #     do anything with given SPN's scope (and don't want to deal with ARM IAM).
  #
  if [ ! -z "${CONNECTED_CLUSTER_SUBSCRIPTION_ID}" ] && [ ! -z "${CONNECTED_CLUSTER_RESOURCE_GROUP}" ]; then
    if [ "${SUBSCRIPTION_ID}" != "${CONNECTED_CLUSTER_SUBSCRIPTION_ID}" ] ||
      [ "${RESOURCE_GROUP_NAME}" != "${CONNECTED_CLUSTER_RESOURCE_GROUP}" ]; then
      echo "$(timestamp) | ERROR | Launcher's [SUBSCRIPTION_ID, RESOURCE_GROUP_NAME : ${SUBSCRIPTION_ID}, ${RESOURCE_GROUP_NAME}] do not match existing Connected Cluster [${CONNECTED_CLUSTER_SUBSCRIPTION_ID} , ${CONNECTED_CLUSTER_RESOURCE_GROUP}]"
      exit 1
    fi
  fi
  if [ ! -z "${DATA_CONTROLLER_SUBSCRIPTION_ID}" ] && [ ! -z "${DATA_CONTROLLER_RESOURCE_GROUP}" ]; then
    if [ "${SUBSCRIPTION_ID}" != "${DATA_CONTROLLER_SUBSCRIPTION_ID}" ] ||
      [ "${RESOURCE_GROUP_NAME}" != "${DATA_CONTROLLER_RESOURCE_GROUP}" ]; then
      echo "$(timestamp) | ERROR | Launcher's [SUBSCRIPTION_ID, RESOURCE_GROUP_NAME : ${SUBSCRIPTION_ID}, ${RESOURCE_GROUP_NAME}] do not match existing Data Controller [${DATA_CONTROLLER_SUBSCRIPTION_ID} , ${DATA_CONTROLLER_RESOURCE_GROUP}]"
      exit 1
    fi
  fi
  if [ ! -z "${CONNECTED_CLUSTER_LOCATION}" ]; then
    if [ "${LOCATION}" != "${CONNECTED_CLUSTER_LOCATION}" ]; then
      echo "$(timestamp) | ERROR | Launcher's LOCATION (${LOCATION}) does not match existing Connected Cluster (${CONNECTED_CLUSTER_LOCATION}), cannot cleanup existing state, exiting."
      exit 1
    fi
  fi
  if [ ! -z "${DATA_CONTROLLER_LOCATION}" ]; then
    if [ "${LOCATION}" != "${DATA_CONTROLLER_LOCATION}" ]; then
      echo "$(timestamp) | ERROR | Launcher's LOCATION (${LOCATION}) does not match existing Data Controller (${DATA_CONTROLLER_LOCATION}), cannot cleanup existing state, exiting."
      exit 1
    fi
  fi

  echo "=================================================================================="
  echo "$(timestamp) | INFO | Resource check completed."
  echo "=================================================================================="
}

generate_env_vars() {
  # Source from Pod spec as some of these variables
  # are overwritten during current-state healthcheck
  source "${scriptPath}"/config/.test.env
  # For all random values
  export TIMESTAMP=$(date +"%s")
  # Names
  export CONNECTED_CLUSTER_NAME="cc${TIMESTAMP}"
  export DATA_CONTROLLER_NAME="dc${TIMESTAMP}"
  # Namespaces
  export DATA_CONTROLLER_NAMESPACE="ns${TIMESTAMP}"
  export CUSTOM_LOCATION_NAME="${DATA_CONTROLLER_NAMESPACE}"
  # Set for downstream use in Tests
  export CLUSTER_NAME=${DATA_CONTROLLER_NAMESPACE}
  export ARC_NAMESPACE=${DATA_CONTROLLER_NAMESPACE}
  # Set from pod env var
  export DATA_CONTROLLER_CONNECTIVITY="${CONNECTIVITY_MODE}"
  # Set to same RG, subscription and location due to 4-in-1 limitation
  export CONNECTED_CLUSTER_LOCATION="${LOCATION}"
  export DATA_CONTROLLER_LOCATION="${LOCATION}"
  export DATA_CONTROLLER_RESOURCE_GROUP="${RESOURCE_GROUP_NAME}"
  export CONNECTED_CLUSTER_RESOURCE_GROUP="${RESOURCE_GROUP_NAME}"
  export DATA_CONTROLLER_SUBSCRIPTION_ID="${SUBSCRIPTION_ID}"
  export CONNECTED_CLUSTER_SUBSCRIPTION_ID="${SUBSCRIPTION_ID}"
  # Set azdata username, password - if not exists
  export AZDATA_USERNAME="${AZDATA_USERNAME:-$(echo "controlleradmin")}"
  export AZDATA_PASSWORD="${AZDATA_PASSWORD:-$(head -c 16 /dev/urandom | base64)}"
}

# Authenticates to Kubernetes API using the Pod's Service Account
# Token
#
kube_login_sa() {
  echo "$(timestamp) | INFO | Authenticating to Kubernetes as Service Account"
  echo ""
  APISERVER=https://kubernetes.default.svc/
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt >ca.crt

  kubectl config set-cluster arc-ci-launcher \
    --embed-certs=true \
    --server="${APISERVER}" \
    --certificate-authority=./ca.crt

  kubectl config set-credentials arc-ci-launcher --token="${TOKEN}"

  echo "$(timestamp) | INFO | Setting kubeconfig"
  kubectl config set-context arc-ci-launcher \
    --cluster=arc-ci-launcher \
    --user=arc-ci-launcher \
    --namespace=default

  kubectl config use-context arc-ci-launcher

  export KUBECONFIG="${HOME}/.kube/config"
  echo ""
  echo "$(timestamp) | INFO | KUBECONFIG: ${KUBECONFIG}"
}

# Prints a string with length n with n '*'s instead
#
obfuprint() {
  printf '%s\n' "${1//?/*}"
}

# Replaces declared secrets with *
#
obfusecret() {
  K=$1
  V=$2
  declare -a SECRETS=(
    "AZDATA_PASSWORD"
    "DOCKER_PASSWORD"
    "LOGS_STORAGE_ACCOUNT_SAS"
    "SPN_CLIENT_SECRET"
    "WORKSPACE_SHARED_KEY"
  )
  if [[ " ${SECRETS[@]} " =~ " ${K} " ]]; then
    echo "${K}=$(obfuprint ${V})"
  else
    echo "${K}=${V}"
  fi
}

# Prints EULA to screen
#
print_eula() {
  readonly eulaPath="/usr/share/doc/arc/SupplementalEULA-AzureArcDataServices.txt"
  if [ -f "${eulaPath}" ]; then
    cat "${eulaPath}"
  else
    exit 1
  fi
  echo "----------------------------------------------------------------------------------"
  echo ""
}

# Alphabetically print env vars, leaving out secrets
#
print_env_sorted() {
  echo "$(timestamp) | INFO | Running with environment variables:"
  echo ""
  while IFS='=' read -r k v ; do
    obfusecret "${k}" "${v}"
  done < <(env -0 | sort -z | tr '\0' '\n\r')
  echo ""
}

# Printing launcher artifact version
#
print_launcher_version() {
  export LAUNCHER_IMAGE=$(kubectl get pod ${LAUNCHER_NAME} -n ${LAUNCHER_NAMESPACE} -o=jsonpath='{.spec.containers[0].image}')
  export LAUNCHER_MODE="${LAUNCHER_MODE:-$(echo "DEFAULT")}"
  echo "---------------------------------------------------------------"
  echo "$(timestamp) | INFO | LAUNCHER_MODE is set to: ${LAUNCHER_MODE}"
  echo "---------------------------------------------------------------"
  echo "$(timestamp) | INFO | Arc Data Release artifacts received through launcher image: ${LAUNCHER_IMAGE}"
  echo "$(timestamp) | INFO | | "
  echo "$(timestamp) | INFO | └── 1. Extension release train: ${ARC_DATASERVICES_EXTENSION_RELEASE_TRAIN}"
  echo "$(timestamp) | INFO |     └── 2. Extension version: ${ARC_DATASERVICES_EXTENSION_VERSION_TAG}"
  echo "$(timestamp) | INFO |         └── 3. Image tag: ${DOCKER_TAG}"
  echo "$(timestamp) | INFO |             └── 4. az arcdata extension version: $(az extension show -n arcdata | jq .version)"
}

# Printing files in the launcher from $HOME
#
print_launcher_files() {
  echo "$(timestamp) | INFO | Launcher container contains the following files (depth 4) as of: $(date)"
  echo ""
  echo "$(pwd)"
  tree -L 4
  echo ""
}

# Print cli tooling dependencies
#
print_cli_dependencies() {
  echo "$(timestamp) | INFO | Running on following cluster:"
  kubectl cluster-info
  echo ""
  echo "$(timestamp) | INFO | Using the following tools:"
  az --version
  jq --version
  kubectl version
  sonobuoy version
  yq --version
  echo ""
}

# Generate Sonobuoy run script and execute it
#
run_sonobuoy_tests() {
  echo "=================================================================================="
  echo "$(timestamp) | INFO | Launching Sonobuoy test suite"
  echo "=================================================================================="
  # "sonobuoy retrieve" will pull logs here per plugin
  #
  export DEBUG_LOGS_DIRECTORY="${scriptPath}/debuglogs/sonobuoy"

  # run test by calling run-sonobuoy-tests. For CI, the argument to sonobuoy
  # should be "all", which will run the INTERSECTION of:
  # - test suites found in projects/test/testgroups
  # AND
  # -test suites listed in projects/test/sre/test-order-schema.txt.
  #
  echo "$(timestamp) | INFO | Data Controller control.json:"
  cat "${scriptPath}/custom/control.json" | jq
  
  if [ "$DATA_CONTROLLER_CONNECTIVITY" == "indirect" ]; then
    export TESTS="${TESTS_INDIRECT}"
  elif [ "$DATA_CONTROLLER_CONNECTIVITY" == "direct" ]; then
    export TESTS="${TESTS_DIRECT}"
  else
    echo "$(timestamp) | ERROR | Invalid connectivity mode supplied: ${DATA_CONTROLLER_CONNECTIVITY}"
    exit 1
  fi
  if [ -z "${TESTS}" ]
     [ "${TESTS}" == " " ]; then
    echo "$(timestamp) | ERROR | No tests found."
    exit 1
  fi

  echo "----------------------------------------------------------------------------------"
  echo "$(timestamp) | INFO | Launching Sonobuoy test suite based on mode: ${DATA_CONTROLLER_CONNECTIVITY}"
  echo "$(timestamp) | INFO | Running tests: ${TESTS}"
  echo "----------------------------------------------------------------------------------"
  
  # Keep going despite errors in test script exit code
  set +e; "${scriptPath}"/run-sonobuoy-tests.sh "${TESTS}"; set -e;
  local_test_rc=$?
  if [ $local_test_rc -ne 0 ]; then
    echo "$(timestamp) | ERROR | Test failed, rc ${local_test_rc}"
    test_rc=$local_test_rc
  fi

  echo "=================================================================================="
  echo "$(timestamp) | INFO | Completed Sonobuoy tests with return code: ${test_rc}."
  echo "=================================================================================="
}

# Sets verbosity of azure cli and command line
# Can enable manually per script via `VERBOSE='true' set_verbosity`
#
set_verbosity() {
  if [[ -z "${VERBOSE}" ]]; then
    echo "$(timestamp) | INFO | Verbose flag not set, will default to false"
  else
    echo "$(timestamp) | INFO | Verbose flag set to ${VERBOSE}"
    if [ "${VERBOSE}" = 'true' ]; then
      # Used throughout for Azure CLI calls
      export VERBOSE=1
      # Prints out the set -x commands with yellow >>> highlights
      PS4="\033[1;33m>>>\033[0m "
      set -x
    else
      unset VERBOSE
      az config set core.only_show_errors=true --only-show-errors
    fi
  fi
}

# Sets up Arcdata pre-reqs and Data Controller
#
setup_arcdata() {
  export DELETE_FLAG=false
  echo "$(timestamp) | INFO | Setting up Data Controller pre-reqs in Mode: ${DATA_CONTROLLER_CONNECTIVITY}"
  "${scriptPath}"/launch-direct-mode-prereqs.sh
  echo "$(timestamp) | INFO | Setting up Data Controller in Mode: ${DATA_CONTROLLER_CONNECTIVITY}"
  "${scriptPath}"/launch-data-controller.sh
  echo "=================================================================================="
  echo "$(timestamp) | INFO | Setup complete."
  echo "=================================================================================="
}

# HH:MM:SS
#
function timestamp() {
  date +"%T"
}

# Simple conversion function
#
true_if_nonempty() {
  if [ -z "$1" ]; then
    echo "false"
  else
    echo "true"
  fi
}

# Upload test results to blob for ADO to download, usable for remote Kubernetes
# Clusters to report on test results.
#
#    0: No attempt
#    1: Success
#    -1: Failure
#
upload_test_results() {
  echo "=================================================================================="
  echo "$(timestamp) | INFO | Uploading test results to blob"
  echo "=================================================================================="
  if [ "${UPLOAD_COMPLETE}" != "1" ]; then
    TARBALL="${LAUNCHER_NAME}-$(date +%Y%m%d-%H%M%S).tar.gz"
    echo "$(timestamp) | INFO | Generating tarball ${TARBALL}"
    
    rm -rf "${scriptPath}/upload"
    mkdir -p "${scriptPath}/upload"

    # arcdata, sonobuoy logs + plugin, control.json, ignore not found
    cp -R "${scriptPath}/debuglogs" "${scriptPath}/upload/" || :
    cp -R "${scriptPath}/sre-output" "${scriptPath}/upload/" || :
    cp -R "${scriptPath}/custom" "${scriptPath}/upload/" || :

    # Logs of self up to this point
    kubectl logs "${LAUNCHER_NAME}" -n "${LAUNCHER_NAMESPACE}" > "${scriptPath}/upload/${LAUNCHER_NAME}.log"

    # tar only upload folder for reduced hierarchy
    tar -czf ${TARBALL} -C "${scriptPath}/upload" .
    
    echo "$(timestamp) | INFO | Creating blob container ${LOGS_STORAGE_CONTAINER}"
    STORAGE_CONTAINER_STATUS=$(az storage container create -n ${LOGS_STORAGE_CONTAINER} --account-name ${LOGS_STORAGE_ACCOUNT} --sas-token ${LOGS_STORAGE_ACCOUNT_SAS})
    echo ${STORAGE_CONTAINER_STATUS} | jq 

    echo "$(timestamp) | INFO | Uploading blob ${TARBALL}"
    BLOB_UPLOAD_STATUS=$(az storage blob upload --file ${TARBALL} --name ${TARBALL} --container-name ${LOGS_STORAGE_CONTAINER} --account-name ${LOGS_STORAGE_ACCOUNT} --sas-token ${LOGS_STORAGE_ACCOUNT_SAS})
    echo ${BLOB_UPLOAD_STATUS} | jq

    BLOB_UPLOAD_TIMESTAMP=$(echo $BLOB_UPLOAD_STATUS | jq -r .lastModified)
    if [ "${BLOB_UPLOAD_TIMESTAMP}" != "null" ] && [ ! -z "${BLOB_UPLOAD_TIMESTAMP}" ]; then
      echo "$(timestamp) | INFO | Blob upload success timestamp: ${BLOB_UPLOAD_TIMESTAMP}"
      export UPLOAD_COMPLETE=1
    else
      echo "$(timestamp) | WARNING | Blob upload failed."
      export UPLOAD_COMPLETE=-1
    fi
  fi
  echo "=================================================================================="
  echo "$(timestamp) | INFO | Upload status: ${UPLOAD_COMPLETE}."
  echo "==================================================================================" 
}