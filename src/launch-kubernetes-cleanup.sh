#!/bin/bash
#
#     This script performs cleanup of residual kubernetes components common to both
#     direct and indirect mode - it is idempotent via --ignore-not-found=true
#
#

# Keep going despite errors during cleanup
set +e +x

scriptPath=$(dirname "$0")
source "${scriptPath}"/launch-common.sh

# Namespace independent resources
#
echo "$(timestamp) | INFO | Deleting Arc Data Cluster Roles and Bindings"
# TODO: Figure out a way to make the label modular (i.e. how to RegEx the 1.0.0)
kubectl delete clusterrolebinding -l "helm.sh/chart=arcdataservices-1.0.0" --ignore-not-found=true
kubectl delete clusterrole -l "helm.sh/chart=arcdataservices-1.0.0" --ignore-not-found=true
kubectl delete clusterrolebinding "${DATA_CONTROLLER_NAMESPACE}:crb-deployer" --ignore-not-found=true
kubectl delete clusterrole "${DATA_CONTROLLER_NAMESPACE}:cr-deployer" --ignore-not-found=true

echo "$(timestamp) | INFO | Deleting Arc Data CRDs"
kubectl delete crd $(kubectl get crd | grep arcdata | cut -f1 -d' ') --ignore-not-found=true

# Namespace dependent resources - we query in here because
# different modes may/may not have cleaned up post delete
#
if [ ! -z "${DATA_CONTROLLER_NAMESPACE}" ]; then
  DATA_CONTROLLER_NAMESPACE_QUERY=$(kubectl get namespace ${DATA_CONTROLLER_NAMESPACE} --ignore-not-found=true)
  DATA_CONTROLLER_NAMESPACE_EXISTS=$(true_if_nonempty "${DATA_CONTROLLER_NAMESPACE_QUERY}")
fi

if [ "${DATA_CONTROLLER_NAMESPACE_EXISTS}" == 'true' ]; then
  echo "$(timestamp) | INFO | Deleting Arc Data Mutating Webhook Configs"
  kubectl delete mutatingwebhookconfiguration arcdata.microsoft.com-webhook-"${DATA_CONTROLLER_NAMESPACE}" --ignore-not-found=true

  echo "$(timestamp) | INFO | Cleaning up PVCs and PVs from tests"
  declare -a used_pvc_array
  declare -a all_pvc_array
  used_pvc_array=($(kubectl get pods -o json -n ${DATA_CONTROLLER_NAMESPACE} | jq -j '.items[] | "\(.metadata.namespace), \(.metadata.name), \(.spec.volumes[].persistentVolumeClaim.claimName)\n"' | grep -v null | tail -n +2 | awk '{print $3}'))
  all_pvc_array=($(kubectl get pvc -o json -n ${DATA_CONTROLLER_NAMESPACE} | jq -j '.items[] | "\(.metadata.name) \n"' | grep -v null | tail -n +2 | awk '{print $1}'))

  # Loop over all_pvc_array and delete those that are not in used_pvc_array
  #
  for i in ${!all_pvc_array[@]}; do
    pvc=${all_pvc_array[$i]}
    if ! [[ "${used_pvc_array[@]}" =~ "${pvc}" ]]; then
      echo "Cleaning up leftover PVC ${pvc}..."
      kubectl delete pvc $pvc -n ${DATA_CONTROLLER_NAMESPACE}
    fi
  done

  # Kubernetes updates the PV status asynchronously after PVC release, so we sleep.
  #
  # We could also build up an array of PVs from the the PVCs above and delete those,
  # but the problem is this wouldn't be a proper cleanup if there were `failed` PVs
  # that were left over from the tests (which aren't part of the PVCs anymore), so 
  # this way leaves the cluster in a cleaner state, albeit less elegant.
  echo "$(timestamp) | INFO | Waiting 15 seconds for PV's to be released..."
  sleep 15

  # Delete leftover pvs that aren't 'Bound' to Pods or 'Available' for binding
  # Possible phases: https://cs.github.com/kubernetes/kubernetes/blob/f5956716e3a92fba30c81635c68187653f7567c2/pkg/apis/core/types.go#L579
  #   
  #   Pending, Available, Bound, Released, Failed.
  #
  kubectl get pv -o json | 
  jq -r ".items[] | select(.spec.storageClassName == \"${KUBERNETES_STORAGECLASS}\") | select((.status.phase != \"Bound\") and (.status.phase != \"Available\") and (.status.phase != \"Pending\")) | .metadata.name" |
  while read pv; do
      echo "INFO | Cleaning up PV ${pv}..."
      kubectl delete pv $pv --ignore-not-found=true
  done

  echo "$(timestamp) | INFO | Deleting Arc Data Namespace: ${DATA_CONTROLLER_NAMESPACE}"
  kubectl delete namespace ${DATA_CONTROLLER_NAMESPACE} --force --grace-period=0 --ignore-not-found=true
fi

echo "----------------------------------------------------------------------------------"
echo "$(timestamp) | INFO | Kubernetes resource cleanup complete."
echo "----------------------------------------------------------------------------------"
exit 0
