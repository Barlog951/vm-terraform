#!/bin/bash

################################################################################
# generate_keys.sh
#
# Generates SSH key for Packer user and uses existing Ed25519 key
# for VM access. Updates cloud-init configurations accordingly.
################################################################################

set -euo pipefail

# Source environment variables
if [[ -f "../env.sh" ]]; then
    source "../env.sh"
else
    echo "Error: env.sh not found!"
    exit 1
fi

# Default paths if not set in env.sh
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh}"
PACKER_KEY_NAME="${PACKER_KEY_NAME:-packer}"
EXISTING_SSH_KEY="${EXISTING_SSH_KEY:-$HOME/.ssh/id_ed25519.pub}"  # Changed to Ed25519

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if a public key exists and is valid
check_public_key() {
    local key_path=$1
    if [[ ! -f "${key_path}" ]]; then
        echo -e "${RED}Error: SSH public key not found at ${key_path}${NC}"
        return 1
    fi

    # Validate the key format
    if ! ssh-keygen -l -f "${key_path}" &>/dev/null; then
        echo -e "${RED}Error: Invalid SSH public key at ${key_path}${NC}"
        return 1
    fi

    # Check if it's an Ed25519 key
    local key_type=$(ssh-keygen -l -f "${key_path}" | awk '{print $4}')
    if [[ "${key_type}" != "ED25519" ]]; then
        echo -e "${YELLOW}Note: Your key is not Ed25519 (type: ${key_type})${NC}"
        echo -e "${YELLOW}This will still work, but Ed25519 is recommended for better security${NC}"
    fi

    return 0
}

# Function to generate Packer SSH key if it doesn't exist
generate_packer_key() {
    local key_path="${SSH_KEY_PATH}/${PACKER_KEY_NAME}"

    if [[ -f "${key_path}" ]]; then
        echo -e "${YELLOW}Packer key ${key_path} already exists${NC}"

        # Validate the key
        if ssh-keygen -l -f "${key_path}" &>/dev/null; then
            echo -e "${GREEN}Key is valid${NC}"
            return 0
        else
            echo -e "${RED}Key is invalid!${NC}"
            echo -n "Do you want to backup and regenerate? [y/N] "
            read -r response
            if [[ "${response}" =~ ^[Yy]$ ]]; then
                mv "${key_path}" "${key_path}.bak.$(date +%Y%m%d-%H%M%S)"
                mv "${key_path}.pub" "${key_path}.pub.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
            else
                echo "Exiting..."
                exit 1
            fi
        fi
    fi

    # Create .ssh directory if it doesn't exist
    mkdir -p "${SSH_KEY_PATH}"
    chmod 700 "${SSH_KEY_PATH}"

    # Generate Ed25519 key for Packer
    echo -e "${GREEN}Generating Ed25519 key for Packer: ${key_path}${NC}"
    ssh-keygen -t ed25519 -f "${key_path}" -N "" -C "packer-generated-key-$(date +%Y%m%d)"

    # Set correct permissions
    chmod 600 "${key_path}"
    chmod 644 "${key_path}.pub"
}

# Function to update cloud-init user-data with the public keys
update_cloud_init() {
    local user_data="../packer/files/cloud-init/user-data"
    local packer_pub_key=$(cat "${SSH_KEY_PATH}/${PACKER_KEY_NAME}.pub")
    local user_pub_key=$(cat "${EXISTING_SSH_KEY}")

    # Create directories if they don't exist
    mkdir -p "$(dirname "${user_data}")"

    # Backup existing user-data if it exists
    if [[ -f "${user_data}" ]]; then
        cp "${user_data}" "${user_data}.bak.$(date +%Y%m%d-%H%M%S)"
    fi

    # Update user-data with the keys
    cat > "${user_data}" << EOF
#cloud-config
autoinstall:
  version: 1
  identity:
    hostname: ubuntu-template
    username: packer
    password: ""
  ssh:
    install-server: true
    allow-pw: false
  ssh_authorized_keys:
    - "${packer_pub_key}"  # Packer temporary key (will be removed after template creation)
    - "${user_pub_key}"    # Your Ed25519 SSH key
  packages:
    - openssh-server
    - cloud-init
    - curl
    - wget
EOF

    echo -e "${GREEN}Updated ${user_data} with SSH keys${NC}"

    # Create empty meta-data if it doesn't exist
    touch "$(dirname "${user_data}")/meta-data"
}

# Main execution
echo "Starting SSH key configuration..."

# Check existing user SSH key
echo -e "\n${GREEN}Checking your Ed25519 SSH key...${NC}"
if ! check_public_key "${EXISTING_SSH_KEY}"; then
    echo -e "${RED}Please ensure your SSH public key exists at ${EXISTING_SSH_KEY}${NC}"
    echo "Or set EXISTING_SSH_KEY in env.sh to point to your public key"
    exit 1
fi
echo -e "${GREEN}Found valid SSH key: ${EXISTING_SSH_KEY}${NC}"

# Generate Packer key
echo -e "\n${GREEN}Generating Packer SSH key...${NC}"
generate_packer_key

# Update cloud-init configuration
echo -e "\n${GREEN}Updating cloud-init configuration...${NC}"
update_cloud_init

# Check and update Packer configuration
echo -e "\n${GREEN}Checking Packer configuration...${NC}"
PACKER_CONFIG="../packer/ubuntu.pkr.hcl"
if [[ -f "${PACKER_CONFIG}" ]]; then
    # Check if the SSH key path needs to be updated
    if ! grep -q "${SSH_KEY_PATH}/${PACKER_KEY_NAME}" "${PACKER_CONFIG}"; then
        echo -e "${YELLOW}Packer configuration might need updating with the correct SSH key path${NC}"
        echo -e "${YELLOW}Please check ${PACKER_CONFIG} and update ssh_private_key_file if needed${NC}"
    else
        echo -e "${GREEN}Packer configuration already contains the correct SSH key path${NC}"
    fi
fi

echo -e "\n${GREEN}SSH key configuration complete!${NC}"
echo "Locations:"
echo "Packer key: ${SSH_KEY_PATH}/${PACKER_KEY_NAME}{,.pub} (temporary, will be removed after template creation)"
echo "Your SSH key: ${EXISTING_SSH_KEY}"

# Remind about env.sh updates and write directly if possible
echo -e "\n${YELLOW}Updating env.sh with these key paths:${NC}"
ENV_PATH="../env.sh"
if [[ -f "${ENV_PATH}" && -w "${ENV_PATH}" ]]; then
    # Backup env.sh
    cp "${ENV_PATH}" "${ENV_PATH}.bak.$(date +%Y%m%d-%H%M%S)"
    
    # Update or add the key paths
    if grep -q "PACKER_SSH_PRIVATE_KEY_FILE" "${ENV_PATH}"; then
        sed -i "s|export PACKER_SSH_PRIVATE_KEY_FILE=.*|export PACKER_SSH_PRIVATE_KEY_FILE=\"${SSH_KEY_PATH}/${PACKER_KEY_NAME}\"|" "${ENV_PATH}"
    else
        echo "export PACKER_SSH_PRIVATE_KEY_FILE=\"${SSH_KEY_PATH}/${PACKER_KEY_NAME}\"" >> "${ENV_PATH}"
    fi
    
    if grep -q "PACKER_SSH_PUBLIC_KEY_FILE" "${ENV_PATH}"; then
        sed -i "s|export PACKER_SSH_PUBLIC_KEY_FILE=.*|export PACKER_SSH_PUBLIC_KEY_FILE=\"${SSH_KEY_PATH}/${PACKER_KEY_NAME}.pub\"|" "${ENV_PATH}"
    else
        echo "export PACKER_SSH_PUBLIC_KEY_FILE=\"${SSH_KEY_PATH}/${PACKER_KEY_NAME}.pub\"" >> "${ENV_PATH}"
    fi
    
    if grep -q "EXISTING_SSH_KEY" "${ENV_PATH}"; then
        sed -i "s|export EXISTING_SSH_KEY=.*|export EXISTING_SSH_KEY=\"${EXISTING_SSH_KEY}\"|" "${ENV_PATH}"
    else
        echo "export EXISTING_SSH_KEY=\"${EXISTING_SSH_KEY}\"" >> "${ENV_PATH}"
    fi
    
    echo -e "${GREEN}✓ env.sh updated successfully!${NC}"
else
    echo -e "${YELLOW}Please manually update your env.sh file with these paths:${NC}"
    echo "export PACKER_SSH_PRIVATE_KEY_FILE=\"${SSH_KEY_PATH}/${PACKER_KEY_NAME}\""
    echo "export PACKER_SSH_PUBLIC_KEY_FILE=\"${SSH_KEY_PATH}/${PACKER_KEY_NAME}.pub\""
    echo "export EXISTING_SSH_KEY=\"${EXISTING_SSH_KEY}\""
fi