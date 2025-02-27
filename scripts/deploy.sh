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

# Function to build template using Packer with error handling
build_template() {
    log_message "INFO" "Building new template using Packer..."
    cd "${PROJECT_ROOT}/packer"

    # Backup any existing log
    if [[ -f "${PROJECT_ROOT}/packer/packer.log" ]]; then
        mv "${PROJECT_ROOT}/packer/packer.log" "${PROJECT_ROOT}/packer/packer.log.$(date +%Y%m%d%H%M%S).bak"
    fi

    # Initialize Packer
    log_message "INFO" "Starting Packer init..."
    if ! packer init ubuntu.pkr.hcl; then
        log_message "ERROR" "${RED}Packer initialization failed!${NC}"
        return 1
    fi

    # Build template
    log_message "INFO" "Starting Packer build..."
    local start_time=$(date +%s)
    if ! PACKER_LOG=1 PACKER_LOG_PATH="${PROJECT_ROOT}/packer/packer.log" \
        packer build \
            -var "vsphere_server=${VSPHERE_SERVER}" \
            -var "vsphere_user=${VSPHERE_USER}" \
            -var "vsphere_password=${VSPHERE_PASSWORD}" \
            -var "vsphere_datacenter=${VSPHERE_DATACENTER}" \
            -var "vsphere_cluster=${VSPHERE_CLUSTER}" \
            -var "vsphere_datastore=${VSPHERE_DATASTORE}" \
            -var "vsphere_network=${VSPHERE_NETWORK}" \
            -var "template_name=${TEMPLATE_NAME}" \
            ubuntu.pkr.hcl; then
        log_message "ERROR" "${RED}Packer build failed! Check packer.log for details.${NC}"
        return 1
    fi
    
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log_message "INFO" "${GREEN}Template built successfully in ${duration} seconds!${NC}"
}

# Function to run Terraform with error handling
run_terraform() {
    local action=$1
    cd "${PROJECT_ROOT}/terraform"

    case $action in
        "init")
            log_message "INFO" "Initializing Terraform..."
            if ! terraform init; then
                log_message "ERROR" "${RED}Terraform initialization failed!${NC}"
                return 1
            fi
            ;;
        "plan")
            log_message "INFO" "Creating Terraform plan..."
            if ! terraform plan -out=tfplan; then
                log_message "ERROR" "${RED}Terraform plan creation failed!${NC}"
                return 1
            fi
            ;;
        "apply")
            log_message "INFO" "Applying Terraform configuration..."
            if ! terraform apply -auto-approve tfplan; then
                log_message "ERROR" "${RED}Terraform apply failed!${NC}"
                return 1
            fi
            log_message "INFO" "Running post-apply validation..."
            terraform output -json > "${PROJECT_ROOT}/terraform/last_output.json"
            ;;
        "destroy")
            log_message "INFO" "${RED}Destroying infrastructure...${NC}"
            if ! terraform destroy -auto-approve; then
                log_message "ERROR" "${RED}Terraform destroy failed!${NC}"
                return 1
            fi
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

# Function to verify deployment
verify_deployment() {
    log_message "INFO" "Verifying deployment..."
    
    # Check if Terraform outputs exist
    if [[ -f "${PROJECT_ROOT}/terraform/last_output.json" ]]; then
        local vm_ips=$(jq -r '.vm_ips.value | to_entries[] | "\(.key): \(.value)"' "${PROJECT_ROOT}/terraform/last_output.json" 2>/dev/null)
        
        if [[ -n "$vm_ips" ]]; then
            log_message "INFO" "Deployed VMs:"
            echo "$vm_ips" | while read -r line; do
                log_message "INFO" "  $line"
                
                # Try to ping each VM (optional verification)
                local ip=$(echo "$line" | cut -d ':' -f2 | tr -d ' ')
                if [[ -n "$ip" && "$ip" != "null" ]]; then
                    if ping -c 1 -W 2 "$ip" &>/dev/null; then
                        log_message "INFO" "  ${GREEN}✓ Network reachable${NC}"
                    else
                        log_message "WARN" "  ${YELLOW}⚠ Network unreachable (VM may still be booting)${NC}"
                    fi
                fi
            done
        fi
    fi
}

# Main execution with timing and error handling
main() {
    local start_time=$(date +%s)
    
    # Create new log file with timestamp
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "=== Deployment started at $(date) ===" > "$LOG_FILE"
    log_message "INFO" "Starting deployment process..."

    # Source environment variables
    if [[ -f "${PROJECT_ROOT}/env.sh" ]]; then
        source "${PROJECT_ROOT}/env.sh"
        log_message "INFO" "Environment variables loaded successfully"
    else
        log_message "ERROR" "${RED}env.sh not found!${NC}"
        exit 1
    fi

    # Run validation
    log_message "INFO" "Validating configuration..."
    if ! "${SCRIPT_DIR}/validate.sh"; then
        log_message "ERROR" "${RED}Validation failed! Aborting deployment.${NC}"
        exit 1
    fi
    log_message "INFO" "${GREEN}Validation successful${NC}"

    # Check if template exists, build if needed
    if ! template_exists; then
        log_message "INFO" "Template does not exist, building now..."
        if ! build_template; then
            log_message "ERROR" "${RED}Failed to build template! Aborting deployment.${NC}"
            exit 1
        fi
    else
        log_message "INFO" "${GREEN}Template already exists, continuing with deployment${NC}"
    fi

    # Run Terraform
    log_message "INFO" "Starting Terraform deployment..."
    if ! run_terraform "init" || ! run_terraform "plan" || ! run_terraform "apply"; then
        log_message "ERROR" "${RED}Terraform deployment failed!${NC}"
        exit 1
    fi
    
    # Verify the deployment
    verify_deployment
    
    # Calculate total runtime
    local end_time=$(date +%s)
    local runtime=$((end_time - start_time))
    local minutes=$((runtime / 60))
    local seconds=$((runtime % 60))
    
    log_message "INFO" "${GREEN}Deployment completed successfully in ${minutes}m ${seconds}s!${NC}"
    log_message "INFO" "Log file: ${LOG_FILE}"
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