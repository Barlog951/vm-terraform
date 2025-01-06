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

# Function to check template existence
check_template() {
    echo -e "\n${YELLOW}Checking VM template...${NC}"
    if govc vm.info "${TEMPLATE_NAME:-ubuntu-template}" &>/dev/null; then
        echo -e "${GREEN}✓ Template exists${NC}"
    else
        echo -e "${RED}Error: Template not found${NC}"
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

# Function to check network connectivity
check_network() {
    echo -e "\n${YELLOW}Checking network connectivity...${NC}"

    # Check vCenter connectivity
    if ping -c 1 "${VSPHERE_SERVER}" &>/dev/null; then
        echo -e "${GREEN}✓ Can reach vCenter server${NC}"
    else
        echo -e "${RED}Error: Cannot reach vCenter server${NC}"
        return 1
    fi

    # Check govc connectivity
    if govc about &>/dev/null; then
        echo -e "${GREEN}✓ Can connect to vCenter using govc${NC}"
    else
        echo -e "${RED}Error: Cannot connect to vCenter using govc${NC}"
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