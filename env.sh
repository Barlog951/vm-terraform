#!/bin/bash

ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Decrypt and source secrets
if [ -f "${ENV_DIR}/secrets.env" ]; then
   eval "$(SOPS_AGE_KEY_FILE=~/.sops/default_key sops --decrypt ${ENV_DIR}/secrets.env)"
else
   echo "Error: secrets.env file not found"
   exit 1
fi

# Export vSphere credentials for Terraform
export VSPHERE_SERVER
export VSPHERE_USER
export VSPHERE_PASSWORD

# Infrastructure locations
export VSPHERE_DATACENTER
export VSPHERE_CLUSTER
export VSPHERE_DATASTORE
export VSPHERE_NETWORK

# Template settings
export TEMPLATE_NAME

# SSH key name
export SSH_KEY_NAME

# GOVC settings
export GOVC_INSECURE=1
export GOVC_URL=$VSPHERE_SERVER
export GOVC_USERNAME=$VSPHERE_USER
export GOVC_PASSWORD=$VSPHERE_PASSWORD
export GOVC_DATASTORE=$VSPHERE_DATASTORE
export GOVC_NETWORK=$VSPHERE_NETWORK
export GOVC_DATACENTER=$VSPHERE_DATACENTER

# SSH Key paths (using your existing key)
export SSH_KEY_PATH="$HOME/.ssh"
export EXISTING_SSH_KEY="$SSH_KEY_PATH/$SSH_KEY_NAME"

# Packer settings
export PACKER_LOG=1
export PACKER_LOG_PATH="packer/packer.log"

# Function to validate connection
validate_connection() {
    echo "Testing vCenter connection..."
    if govc about > /dev/null 2>&1; then
        echo "Successfully connected to vCenter!"
    else
        echo "Failed to connect to vCenter. Please check your credentials and network."
        return 1
    fi
}

# Run validation if script is executed (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    validate_connection
fi  # Added missing 'fi'