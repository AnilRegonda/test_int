#!/bin/bash
#
#     Executed in launcher to remove test custom resources,
#     that can be safely executed prior to the removal of
#     data controller
#
#

# Keep going despite errors during cleanup
set +e +x

scriptPath=$(dirname "$0")
source "${scriptPath}"/launch-common.sh

if [[ -z "${DATA_CONTROLLER_NAMESPACE}" ]]; then
    echo "$(timestamp) | ERROR | DATA_CONTROLLER_NAMESPACE must be set for Arc Data Custom Resource cleanup"
    exit 1
fi

kubectl delete sqlmanagedinstances.sql.arcdata.microsoft.com --all -n "${DATA_CONTROLLER_NAMESPACE}" || true
kubectl delete postgresqls.arcdata.microsoft.com --all -n "${DATA_CONTROLLER_NAMESPACE}" || true
kubectl delete exporttasks.tasks.arcdata.microsoft.com --all -n "${DATA_CONTROLLER_NAMESPACE}" || true
kubectl delete sqlmanagedinstancerestoretasks.tasks.sql.arcdata.microsoft.com --all -n "${DATA_CONTROLLER_NAMESPACE}" || true

echo "----------------------------------------------------------------------------------"
echo "$(timestamp) | INFO | Arc data Custom Resource cleanup complete."
echo "----------------------------------------------------------------------------------"
exit 0
