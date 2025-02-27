#!/bin/bash

################################################################################
# validate.sh
#
# Validates the entire configuration before deployment, checking:
# - Environment variables
# - Terraform configurations
# - VM template existence
# - Network connectivity
################################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Load environment variables
if [[ -f "../env.sh" ]]; then
    source "../env.sh"
else
    echo -e "${RED}Error: env.sh not found!${NC}"
    exit 1
fi

echo -e "${YELLOW}Starting configuration validation...${NC}"

# Function to check required environment variables
check_env_vars() {
    local required_vars=(
        "VSPHERE_SERVER"
        "VSPHERE_USER"
        "VSPHERE_PASSWORD"
        "VSPHERE_DATACENTER"
        "VSPHERE_CLUSTER"
        "VSPHERE_DATASTORE"
        "VSPHERE_NETWORK"
    )

    echo -e "\n${YELLOW}Checking environment variables...${NC}"
    local missing_vars=0

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo -e "${RED}Error: $var is not set${NC}"
            missing_vars=1
        else
            echo -e "${GREEN}✓ $var is set${NC}"
        fi
    done

    if [[ $missing_vars -eq 1 ]]; then
        echo -e "${RED}Some required environment variables are missing!${NC}"
        return 1
    fi
}

# Function to check template existence with detailed output
check_template() {
    echo -e "\n${YELLOW}Checking VM template...${NC}"
    local template="${TEMPLATE_NAME:-ubuntu-template}"
    
    if govc vm.info "${template}" &>/dev/null; then
        # Get template details
        local template_info=$(govc vm.info -r "${template}")
        local cpu=$(echo "$template_info" | grep "CPU:" | awk '{print $2}')
        local memory=$(echo "$template_info" | grep "Memory:" | awk '{print $2}')
        local guest_id=$(echo "$template_info" | grep "Guest ID:" | awk '{print $3}')
        
        echo -e "${GREEN}✓ Template exists${NC}"
        echo -e "  - Name: ${template}"
        echo -e "  - CPU: ${cpu}"
        echo -e "  - Memory: ${memory}"
        echo -e "  - Guest OS: ${guest_id}"
    else
        echo -e "${RED}Error: Template '${template}' not found${NC}"
        
        # Check if any templates exist to offer alternatives
        local existing_templates=$(govc vm.info -r -json */templates/* 2>/dev/null | jq -r '.VirtualMachines[].Name' 2>/dev/null)
        if [[ -n "${existing_templates}" ]]; then
            echo -e "${YELLOW}Available templates:${NC}"
            echo "${existing_templates}" | while read -r template_name; do
                echo -e "  - ${template_name}"
            done
        fi
        
        return 1
    fi
}

# Function to validate Terraform configurations
validate_terraform() {
    echo -e "\n${YELLOW}Validating Terraform configurations...${NC}"

    # Move to terraform directory
    cd ../terraform

    # Initialize Terraform
    echo "Initializing Terraform..."
    if terraform init -backend=false &>/dev/null; then
        echo -e "${GREEN}✓ Terraform initialized successfully${NC}"
    else
        echo -e "${RED}Error: Terraform initialization failed${NC}"
        return 1
    fi

    # Validate Terraform configuration
    echo "Validating Terraform configuration..."
    if terraform validate; then
        echo -e "${GREEN}✓ Terraform configuration is valid${NC}"
    else
        echo -e "${RED}Error: Terraform validation failed${NC}"
        return 1
    fi

    # Check Terraform format
    echo "Checking Terraform formatting..."
    if terraform fmt -check; then
        echo -e "${GREEN}✓ Terraform files are properly formatted${NC}"
    else
        echo -e "${YELLOW}Warning: Some Terraform files need formatting${NC}"
        echo "Run 'terraform fmt' to fix formatting"
    fi
}

# Function to check network connectivity with enhanced diagnostics
check_network() {
    echo -e "\n${YELLOW}Checking network connectivity...${NC}"
    local server="${VSPHERE_SERVER}"

    # Check vCenter connectivity with ping
    echo -n "Testing ping to vCenter server... "
    if ping -c 1 -W 5 "${server}" &>/dev/null; then
        echo -e "${GREEN}✓ Successful${NC}"
    else
        echo -e "${RED}Failed${NC}"
        echo -e "${YELLOW}Attempting alternative connectivity checks...${NC}"
        
        # Try a TCP connection to port 443 (vCenter web interface)
        echo -n "Testing TCP connection to vCenter HTTPS port... "
        if nc -z -w 5 "${server}" 443 &>/dev/null; then
            echo -e "${GREEN}✓ Successful${NC}"
        else
            echo -e "${RED}Failed${NC}"
            echo -e "${RED}Error: Cannot reach vCenter server. Please check your network configuration.${NC}"
            return 1
        fi
    fi

    # Test vCenter API connectivity with govc
    echo -n "Testing vCenter API connectivity... "
    local start_time=$(date +%s)
    if govc about &>/dev/null; then
        local end_time=$(date +%s)
        local response_time=$((end_time - start_time))
        echo -e "${GREEN}✓ Connected in ${response_time} seconds${NC}"
        
        # Get vCenter info
        local about_info=$(govc about)
        local vcenter_version=$(echo "$about_info" | grep "Version:" | awk '{print $2}')
        local vcenter_build=$(echo "$about_info" | grep "Build:" | awk '{print $2}')
        
        echo -e "  - vCenter Version: ${vcenter_version}"
        echo -e "  - vCenter Build: ${vcenter_build}"
    else
        echo -e "${RED}Failed${NC}"
        echo -e "${RED}Error: Cannot connect to vCenter using govc. Please check your credentials.${NC}"
        return 1
    fi
}

# Main execution
echo "Starting validation at $(date)"

# Run all checks
check_env_vars || exit 1
check_network || exit 1
check_template || exit 1
validate_terraform || exit 1

echo -e "\n${GREEN}All validations passed successfully!${NC}"
echo "You can now proceed with deployment."