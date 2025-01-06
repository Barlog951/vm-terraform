#!/bin/bash

################################################################################
# deploy.sh
#
# Handles the complete deployment process:
# 1. Validates configuration
# 2. Builds template if needed
# 3. Deploys VMs using Terraform
# 4. Ensures network connectivity
################################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Log file
LOG_FILE="${PROJECT_ROOT}/deployment.log"
CURRENT_DATE=$(date '+%Y-%m-%d_%H-%M-%S')

# Function to log messages
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

# Function to build template using Packer
build_template() {
    log_message "INFO" "Building new template using Packer..."
    cd "${PROJECT_ROOT}/packer"

    # Initialize Packer
    log_message "INFO" "Starting Packer init..."
    packer init ubuntu.pkr.hcl

    # Build template
    log_message "INFO" "Starting Packer build..."
    PACKER_LOG=1 PACKER_LOG_PATH="${PROJECT_ROOT}/packer/packer.log" \
    packer build \
        -var "vsphere_server=${VSPHERE_SERVER}" \
        -var "vsphere_user=${VSPHERE_USER}" \
        -var "vsphere_password=${VSPHERE_PASSWORD}" \
        -var "vsphere_datacenter=${VSPHERE_DATACENTER}" \
        -var "vsphere_cluster=${VSPHERE_CLUSTER}" \
        -var "vsphere_datastore=${VSPHERE_DATASTORE}" \
        -var "vsphere_network=${VSPHERE_NETWORK}" \
        -var "template_name=${TEMPLATE_NAME}" \
        ubuntu.pkr.hcl
}

# Function to run Terraform
# Update the run_terraform function in deploy.sh:

run_terraform() {
    local action=$1
    cd "${PROJECT_ROOT}/terraform"

    case $action in
        "init")
            log_message "INFO" "Initializing Terraform..."
            terraform init
            ;;
        "plan")
            log_message "INFO" "Creating Terraform plan..."
            terraform plan -out=tfplan
            ;;
        "apply")
            log_message "INFO" "Applying Terraform configuration..."
            terraform apply -auto-approve tfplan

            ;;
        "destroy")
            log_message "INFO" "${RED}Destroying infrastructure...${NC}"
            terraform destroy -auto-approve
            ;;
    esac
}

# Function to check if template exists
template_exists() {
    # Capture the output
    info="$(govc vm.info "${TEMPLATE_NAME}" 2>/dev/null)"

    if [[ -z "${info}" ]]; then
        return 1  # Means "not found"
    else
        return 0  # Means "found"
    fi
}

# Main execution
main() {
    # Create new log file with timestamp
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== Deployment started at $(date) ===" > "$LOG_FILE"

    # Source environment variables
    if [[ -f "${PROJECT_ROOT}/env.sh" ]]; then
        source "${PROJECT_ROOT}/env.sh"
    else
        log_message "ERROR" "${RED}env.sh not found!${NC}"
        exit 1
    fi

    # Run validation
    "${SCRIPT_DIR}/validate.sh"

    # Check if template exists, build if needed
    if ! template_exists; then
        build_template
    fi

    # Run Terraform
    run_terraform "init"
    run_terraform "plan"
    run_terraform "apply"

    log_message "INFO" "${GREEN}Deployment completed successfully!${NC}"
}

# Help message
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  --destroy      Destroy the infrastructure"
    echo "  --validate     Only run validation"
    echo "  --template     Only build template"
}

# Parse command line arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    --destroy)
        source "${PROJECT_ROOT}/env.sh"
        run_terraform "destroy"
        exit 0
        ;;
    --validate)
        source "${PROJECT_ROOT}/env.sh"
        "${SCRIPT_DIR}/validate.sh"
        exit 0
        ;;
    --template)
        source "${PROJECT_ROOT}/env.sh"
        build_template
        exit 0
        ;;
    "")
        main
        ;;
    *)
        echo "Unknown option: $1"
        show_help
        exit 1
        ;;
esac