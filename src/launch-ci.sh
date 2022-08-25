#!/bin/bash
#
#
#       Launches arcdata pre-reqs, deploys data controller
#       and triggers sonobuoy, this should be run as a K8s
#       Pod's entrypoint.
#
#       If the script errors out and is restarted, it will
#       attempt to first perform idempotent cleanup of the
#       previously failed run, before going through the
#       setup steps.
#
#       LAUNCHER_MODE env var lets the script exit at particular
#       at logical stages, the idea is it's useful for pms,
#       devs and customers to stand up the release train env.
#
#       - CLEAN_ONLY: Cleans up and previous Arc residue, exits
#       - SETUP_ONLY: Sets up the current release, exits
#       - DEFAULT: Not used anywhere, executes the full cycle
#
#

set -e +x pipefail

scriptPath=$(dirname "$0")
source "${scriptPath}"/config/.test.env
source "${scriptPath}"/launch-common.sh

trap \
 "{ set +e ; upload_test_results ; }" \
 SIGTERM ERR EXIT

test_rc=0

launch_ci() {

    # =====
    # Prep
    # =====
    set_verbosity
    kube_login_sa
    print_launcher_version
    print_launcher_files
    azure_login_spn
    print_cli_dependencies
    get_and_clean_resources

    if [ "${LAUNCHER_MODE}" == 'CLEAN_ONLY' ]; then echo "$(timestamp) | INFO | Launched in CLEAN_ONLY, exiting."; exit 0; fi

    # ======
    # Setup
    # ======
    generate_env_vars
    print_env_sorted
    setup_arcdata
    debuglogs_arcdata "setup-complete"

    if [ "${LAUNCHER_MODE}" == 'SETUP_ONLY' ]; then echo "$(timestamp) | INFO | Launched in SETUP_ONLY, exiting."; exit 0; fi

    # ====
    # Test
    # ====
    run_sonobuoy_tests
    debuglogs_arcdata "test-complete"

    # =====
    # Clean
    # =====
    get_and_clean_resources
    print_launcher_files

    # =========
    # Send logs
    # =========
    UPLOAD_COMPLETE=0 upload_test_results

}

print_eula
launch_ci

echo "----------------------------------------------------------------------------------"
echo "$(timestamp) | INFO | arc-ci-launcher exiting with code: ${test_rc}."
echo "----------------------------------------------------------------------------------"
exit $test_rc
