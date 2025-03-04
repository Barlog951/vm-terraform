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
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
    # Capture the output with timeout to prevent hanging
    info="$(timeout 10s govc vm.info "${TEMPLATE_NAME}" 2>/dev/null)"

    if [[ -z "${info}" ]]; then
        return 1  # Means "not found"
    else
        return 0  # Means "found"
    fi
}

# Function to verify deployment
verify_deployment() {
    log_message "INFO" "Verifying deployment..."
    
    # Check if Terraform outputs exist with better error handling
    if [[ -f "${PROJECT_ROOT}/terraform/last_output.json" ]]; then
        local vm_names=$(jq -r '.vm_ips.value | keys[]' "${PROJECT_ROOT}/terraform/last_output.json" 2>/dev/null || echo "")
        
        if [[ -n "$vm_names" ]]; then
            log_message "INFO" "╒══════════════════════════════════════════════════════════════"
            log_message "INFO" "│ ${YELLOW}DEPLOYMENT VERIFICATION${NC}"
            log_message "INFO" "╘══════════════════════════════════════════════════════════════"
            
            # Create an array to store unreachable VMs for a second pass
            declare -a unreachable_vms
            
            for vm_name in $vm_names; do
                # Print a header for each VM
                log_message "INFO" "╒──────────────────────────────────────────────────────────────"
                log_message "INFO" "│ ${CYAN}Checking VM: ${vm_name}${NC}"
                log_message "INFO" "╘──────────────────────────────────────────────────────────────"
                
                # Get VM uuid for govc lookup with error handling
                local vm_uuid=$(jq -r ".vm_details.value.\"${vm_name}\".uuid // empty" "${PROJECT_ROOT}/terraform/last_output.json" 2>/dev/null)
                
                if [[ -z "$vm_uuid" ]]; then
                    log_message "WARN" "  ${YELLOW}⚠ Could not find UUID for ${vm_name}${NC}"
                    continue
                fi
                
                # Track if VM is reachable on any network
                local vm_reachable=false
                
                # Get all networks from govc with timeout
                log_message "INFO" "  Discovering all network addresses..."
                local ipv4_addresses=""
                
                # Get IP addresses using a simple approach - start with Terraform data
                local terraform_ip=$(jq -r ".vm_ips.value.\"${vm_name}\" // empty" "${PROJECT_ROOT}/terraform/last_output.json" 2>/dev/null)
                if [[ -n "$terraform_ip" && "$terraform_ip" != "null" ]]; then
                    ipv4_addresses="${terraform_ip}"
                fi
                
                # Now try govc for additional IPs
                local govc_output
                govc_output=$(timeout 5s govc vm.info -vm.uuid="$vm_uuid" 2>/dev/null) || true
                local govc_ip=$(echo "$govc_output" | grep "IP address:" | awk '{print $3}')
                if [[ -n "$govc_ip" && "$govc_ip" != "$terraform_ip" ]]; then
                    if [[ -n "$ipv4_addresses" ]]; then
                        ipv4_addresses="${ipv4_addresses}"$'\n'"${govc_ip}"
                    else
                        ipv4_addresses="${govc_ip}"
                    fi
                fi
                
                # Also try vmware-toolbox-cmd if available via SSH
                if [[ -n "$terraform_ip" ]]; then
                    local ssh_ip_check
                    ssh_ip_check=$(timeout 3s ssh -o StrictHostKeyChecking=no -o ConnectTimeout=2 ubuntu@"$terraform_ip" 'ip addr | grep "inet " | grep -v 127.0.0.1 | awk "{print \$2}" | cut -d/ -f1' 2>/dev/null) || true
                    
                    if [[ -n "$ssh_ip_check" ]]; then
                        while IFS= read -r ip; do
                            if [[ -n "$ip" && ! "$ipv4_addresses" =~ $ip ]]; then
                                ipv4_addresses="${ipv4_addresses}"$'\n'"${ip}"
                            fi
                        done <<< "$ssh_ip_check"
                    fi
                fi
                
                # Clean up the IP list
                if [[ -n "$ipv4_addresses" ]]; then
                    ipv4_addresses=$(echo "$ipv4_addresses" | grep -v "^$" | sort -u)
                fi
                
                # Display discovered IPs
                if [[ -n "$ipv4_addresses" ]]; then
                    log_message "INFO" "  All discovered IPv4 addresses for ${vm_name}:"
                    while IFS= read -r ip; do
                        if [[ -n "$ip" ]]; then
                            log_message "INFO" "    → ${ip}"
                        fi
                    done <<< "$ipv4_addresses"
                else
                    log_message "WARN" "  ${YELLOW}⚠ No IPv4 addresses discovered for ${vm_name}${NC}"
                fi
                
                # Check each network for connectivity
                log_message "INFO" "  Testing network connectivity:"
                local reachable_count=0
                local unreachable_count=0
                
                # Track reachable and unreachable IPs for this VM
                local vm_reachable_ips=""
                local vm_unreachable_ips=""
                
                # Test each IP with better error handling and timeout
                while IFS= read -r ip; do
                    if [[ -n "$ip" && "$ip" != "null" ]]; then
                        # Use timeout to prevent ping from hanging
                        if timeout 3s ping -c 1 -W 2 "$ip" &>/dev/null; then
                            log_message "INFO" "    ${GREEN}✓ Network reachable via ${ip}${NC}"
                            vm_reachable_ips+="${ip} "
                            ((reachable_count++))
                            vm_reachable=true
                        else
                            log_message "INFO" "    ${RED}✗ Network ${ip} not responding${NC}"
                            vm_unreachable_ips+="${ip} "
                            ((unreachable_count++))
                        fi
                    fi
                done <<< "$ipv4_addresses"
                
                # Store IPs in shell variables for later use
                export "reachable_ips_${vm_name//-/_}=$vm_reachable_ips"
                export "unreachable_ips_${vm_name//-/_}=$vm_unreachable_ips"
                
                # VM is considered reachable if at least one IP responds
                if [[ "$vm_reachable" == "true" ]]; then
                    local total_networks=$((reachable_count + unreachable_count))
                    log_message "INFO" "  ${GREEN}✓ VM ${vm_name} is reachable (${reachable_count}/${total_networks} networks)${NC}"
                else
                    log_message "WARN" "  ${YELLOW}⚠ VM ${vm_name}: All networks are unreachable${NC}"
                    unreachable_vms+=("$vm_name")
                fi
            done
            
            # Second pass for unreachable VMs after waiting for them to boot
            if [[ ${#unreachable_vms[@]} -gt 0 ]]; then
                log_message "INFO" "╒══════════════════════════════════════════════════════════════"
                log_message "INFO" "│ ${YELLOW}RETRYING UNREACHABLE VMS${NC}"
                log_message "INFO" "╘══════════════════════════════════════════════════════════════"
                log_message "INFO" "Running govc vm.ip command to force IP update for all VMs..."
                
                # Try to force IP update for all unreachable VMs
                for vm_name in "${unreachable_vms[@]}"; do
                    local vm_uuid=$(jq -r ".vm_details.value.\"${vm_name}\".uuid // empty" "${PROJECT_ROOT}/terraform/last_output.json" 2>/dev/null || echo "")
                    if [[ -n "$vm_uuid" ]]; then
                        log_message "INFO" "  Requesting IP details for ${vm_name}..."
                        timeout 5s govc vm.ip -v4 -vm.uuid="$vm_uuid" >/dev/null 2>&1 || true
                    fi
                done
                
                log_message "INFO" "Waiting 15 seconds for remaining VMs to initialize networks..."
                sleep 15
                
                for vm_name in "${unreachable_vms[@]}"; do
                    log_message "INFO" "╒──────────────────────────────────────────────────────────────"
                    log_message "INFO" "│ ${CYAN}Retrying VM: ${vm_name}${NC}"
                    log_message "INFO" "╘──────────────────────────────────────────────────────────────"
                    
                    local vm_uuid=$(jq -r ".vm_details.value.\"${vm_name}\".uuid // empty" "${PROJECT_ROOT}/terraform/last_output.json" 2>/dev/null)
                    local vm_reachable=false
                    
                    # Get fresh IP information
                    if [[ -n "$vm_uuid" ]]; then
                        log_message "INFO" "  Refreshing network information..."
                        
                        # Get all available IPv4 addresses using the same method as above
                        local fresh_ipv4_addresses=""
                        
                        # Start with Terraform data
                        local terraform_ip=$(jq -r ".vm_ips.value.\"${vm_name}\" // empty" "${PROJECT_ROOT}/terraform/last_output.json" 2>/dev/null)
                        if [[ -n "$terraform_ip" && "$terraform_ip" != "null" ]]; then
                            fresh_ipv4_addresses="${terraform_ip}"
                        fi
                        
                        # Now try govc for additional IPs
                        local govc_output
                        govc_output=$(timeout 5s govc vm.info -vm.uuid="$vm_uuid" 2>/dev/null) || true
                        local govc_ip=$(echo "$govc_output" | grep "IP address:" | awk '{print $3}')
                        if [[ -n "$govc_ip" && "$govc_ip" != "$terraform_ip" ]]; then
                            if [[ -n "$fresh_ipv4_addresses" ]]; then
                                fresh_ipv4_addresses="${fresh_ipv4_addresses}"$'\n'"${govc_ip}"
                            else
                                fresh_ipv4_addresses="${govc_ip}"
                            fi
                        fi
                        
                        # Also try direct govc vm.ip command
                        local direct_ip
                        direct_ip=$(timeout 5s govc vm.ip -v4 -vm.uuid="$vm_uuid" 2>/dev/null) || true
                        if [[ -n "$direct_ip" ]]; then
                            if [[ -n "$fresh_ipv4_addresses" ]]; then
                                fresh_ipv4_addresses="${fresh_ipv4_addresses}"$'\n'"${direct_ip}"
                            else
                                fresh_ipv4_addresses="${direct_ip}"
                            fi
                        fi
                        
                        # Clean up the IP list
                        if [[ -n "$fresh_ipv4_addresses" ]]; then
                            fresh_ipv4_addresses=$(echo "$fresh_ipv4_addresses" | grep -v "^$" | sort -u)
                        fi
                        
                        # Display discovered IPs
                        if [[ -n "$fresh_ipv4_addresses" ]]; then
                            log_message "INFO" "  Fresh IPv4 addresses for ${vm_name}:"
                            while IFS= read -r ip; do
                                if [[ -n "$ip" ]]; then
                                    log_message "INFO" "    → ${ip}"
                                fi
                            done <<< "$fresh_ipv4_addresses"
                        else
                            log_message "WARN" "  ${YELLOW}⚠ No IPv4 addresses discovered for retry${NC}"
                        fi
                        
                        # Reset counters and temp variables for this VM
                        local reachable_count=0
                        local unreachable_count=0
                        local vm_reachable_ips=""
                        local vm_unreachable_ips=""
                        
                        # Test each IP address with better error handling and timeout
                        log_message "INFO" "  Retrying connectivity tests:"
                        
                        while IFS= read -r ip; do
                            if [[ -n "$ip" && "$ip" != "null" ]]; then
                                # Use timeout to prevent ping from hanging
                                if timeout 3s ping -c 1 -W 2 "$ip" &>/dev/null; then
                                    log_message "INFO" "    ${GREEN}✓ Network now reachable via ${ip}${NC}"
                                    vm_reachable_ips+="${ip} "
                                    ((reachable_count++))
                                    vm_reachable=true
                                else
                                    log_message "INFO" "    ${RED}✗ Network ${ip} still not responding${NC}"
                                    vm_unreachable_ips+="${ip} "
                                    ((unreachable_count++))
                                fi
                            fi
                        done <<< "$fresh_ipv4_addresses"
                        
                        # Store IPs in shell variables for later use
                        export "reachable_ips_${vm_name//-/_}=$vm_reachable_ips"
                        export "unreachable_ips_${vm_name//-/_}=$vm_unreachable_ips"
                        
                        # Final status based on connectivity
                        if [[ "$vm_reachable" == "true" ]]; then
                            local total_networks=$((reachable_count + unreachable_count))
                            log_message "INFO" "  ${GREEN}✓ VM ${vm_name} is now reachable (${reachable_count}/${total_networks} networks)${NC}"
                            # Remove from unreachable list by filtering
                            unreachable_vms=("${unreachable_vms[@]/$vm_name}")
                        else
                            log_message "WARN" "  ${YELLOW}⚠ VM ${vm_name}: All networks still unreachable${NC}"
                            
                            # Check VM status for additional info
                            local vm_status=$(timeout 5s govc vm.info -vm.uuid="$vm_uuid" 2>/dev/null) || true
                            local power_state=$(echo "$vm_status" | grep "Power state:" | awk '{print $3}')
                            log_message "INFO" "  VM power state: ${power_state:-unknown}"
                            
                            # Additional VM info if available
                            local host_info=$(echo "$vm_status" | grep "Host:" | awk '{print $2}')
                            if [[ -n "$host_info" ]]; then
                                log_message "INFO" "  VM host: ${host_info}"
                            fi
                            
                            log_message "INFO" "  VM may be operating on an isolated network or still initializing"
                        fi
                    fi
                done
            fi
            
            # Print summary
            log_message "INFO" "╒══════════════════════════════════════════════════════════════"
            log_message "INFO" "│ ${YELLOW}VERIFICATION SUMMARY${NC}"
            log_message "INFO" "╘══════════════════════════════════════════════════════════════"
            
            # Count total and reachable VMs
            local total_vms=$(echo "$vm_names" | wc -w | tr -d ' ')
            local reachable_vms=$((total_vms - ${#unreachable_vms[@]}))
            
            log_message "INFO" "Total VMs: ${total_vms}"
            log_message "INFO" "Reachable VMs: ${reachable_vms}/${total_vms}"
            
            if [[ ${#unreachable_vms[@]} -gt 0 ]]; then
                log_message "WARN" "${YELLOW}Unreachable VMs: ${unreachable_vms[*]}${NC}"
                log_message "INFO" "Note: Some VMs may be on isolated networks or still initializing"
            else
                log_message "INFO" "${GREEN}✓ All VMs are reachable${NC}"
            fi
            
            # Print connection information for all VMs
            log_message "INFO" "╒══════════════════════════════════════════════════════════════"
            log_message "INFO" "│ ${YELLOW}CONNECTION INFORMATION${NC}"
            log_message "INFO" "╘══════════════════════════════════════════════════════════════"
            
            for vm_name in $vm_names; do
                log_message "INFO" "Connection options for ${CYAN}${vm_name}${NC}:"
                
                # Get the reachable IPs for this VM
                local reachable_var="reachable_ips_${vm_name//-/_}"
                local vm_reachable_ips=${!reachable_var-}
                
                # Show SSH commands for reachable IPs
                if [[ -n "$vm_reachable_ips" ]]; then
                    for ip in $vm_reachable_ips; do
                        log_message "INFO" "  ${GREEN}→ ssh ubuntu@${ip}${NC}"
                    done
                elif [[ ! " ${unreachable_vms[*]} " =~ " ${vm_name} " ]]; then
                    # VM is not in unreachable list, but we have no reachable IPs
                    # Try to get primary IP as fallback
                    local primary_ip=$(jq -r ".vm_ips.value.\"${vm_name}\" // empty" "${PROJECT_ROOT}/terraform/last_output.json" 2>/dev/null || echo "")
                    if [[ -n "$primary_ip" && "$primary_ip" != "null" ]]; then
                        log_message "INFO" "  ${BLUE}→ ssh ubuntu@${primary_ip}${NC}"
                    fi
                else
                    # VM is in unreachable list
                    # Show info about unreachable IPs
                    local unreachable_var="unreachable_ips_${vm_name//-/_}"
                    local vm_unreachable_ips=${!unreachable_var-}
                    
                    if [[ -n "$vm_unreachable_ips" ]]; then
                        for ip in $vm_unreachable_ips; do
                            log_message "INFO" "  ${YELLOW}→ ssh ubuntu@${ip} (currently unreachable)${NC}"
                        done
                    else
                        # Last resort: show IP from Terraform
                        local terraform_ip=$(jq -r ".vm_ips.value.\"${vm_name}\" // empty" "${PROJECT_ROOT}/terraform/last_output.json" 2>/dev/null || echo "")
                        if [[ -n "$terraform_ip" && "$terraform_ip" != "null" ]]; then
                            log_message "INFO" "  ${YELLOW}→ ssh ubuntu@${terraform_ip} (currently unreachable)${NC}"
                        else
                            log_message "INFO" "  ${RED}No connection options available${NC}"
                        fi
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