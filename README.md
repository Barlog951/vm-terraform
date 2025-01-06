# Project Deployment Automation

This project automates the creation of VMware VM templates and the deployment of VMs using Packer and Terraform. It ensures secure secrets management using SOPS with AGE, flexible network configurations, and streamlined infrastructure automation.

## Prerequisites

### 1. Environment Requirements:
- VMware vSphere environment  
- govc tool installed (for managing VMware resources)
- Packer installed
- Terraform installed  
- SOPS with AGE installed

### 2. Credentials & SSH Keys:
- SSH keys generated for Packer and user access
- SOPS AGE key generated and configured

### 3. Network & Datastore:
- Predefined vSphere networks (e.g., HOMELAB, LAN, ONLY_INTERNET, YOZZU)
- Access to datastores like BVX-1, BVX-2, or nfs-with-backup

## Setup Instructions

### 1. Initialize SOPS and Manage Secrets
- Generate an AGE key for SOPS:
```bash
age-keygen -o ~/.sops/default_key
```

- Configure .sops.yaml with your AGE public key:
```yaml
creation_rules:
  - path_regex: \.env$
    age: [your-age-public-key]
```

- Encrypt your secrets file:
```bash
sops -e secrets.env > secrets.enc.env
```

- Decrypt and source the environment variables:
```bash
export SOPS_AGE_KEY_FILE=~/.sops/default_key
source <(sops --decrypt secrets.enc.env)
```

### 2. Set Up Environment Variables
- Update env.sh with your VMware vSphere credentials, network, and datastore details:
```bash
source env.sh
```

- Validate the connection to vSphere:
```bash
govc about
```

### 3. Generate SSH Keys
- For Packer:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/packer_key -N ""
```

- For user access:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/vm_key -N ""
```

### 4. Configure Packer and Terraform
- Update Packer configuration:
  - Ensure correct SSH key paths in packer/ubuntu.pkr.hcl
  - Validate the Cloud-Init configuration in packer/files/cloud-init/user-data
- Update Terraform configuration:
  - Adjust VM settings like CPU, memory, and disk size in terraform/variables.tf
  - Verify or update network and IP configuration in terraform/terraform.tfvars

### 5. Deploy Infrastructure
- Use the deploy.sh script for deployment:
```bash
./scripts/deploy.sh [OPTIONS]

Options:
  --template     Build template only
  --validate     Run validation checks
  --destroy      Destroy existing infrastructure
  -h, --help     Show help
```

### 6. Verify Deployment
- Check the deployment in VMware vSphere:
  - Verify the creation of templates and VMs
  - Ensure proper network assignment
- Test SSH access to VMs:
```bash
ssh username@vm_ip -i ~/.ssh/vm_key
```

### 7. Destroy Resources
To clean up deployed resources:
```bash
cd terraform
terraform destroy -auto-approve
```

## Project Structure
```
project/
├── secrets.env            # Encrypted credentials file (SOPS encrypted)
├── .sops.yaml            # SOPS configuration
├── env.sh                # Environment script
├── packer/               # Packer configuration and files
│   ├── files/            # Cloud-Init configuration files
│   ├── scripts/          # VM cleanup and provisioning scripts
│   └── ubuntu.pkr.hcl    # Packer configuration
├── terraform/            # Terraform infrastructure code
│   ├── modules/          # Terraform modules
│   ├── main.tf           # Main Terraform configuration
│   └── variables.tf      # Input variables
└── scripts/              # Deployment scripts
    ├── deploy.sh         # Main deployment script
    ├── validate.sh       # Validation script
    └── generate_keys.sh  # SSH key generation script
```

## Networks and Datastores

### Networks:
- HOMELAB: 10.10.30.0/24
- LAN: 192.168.1.0/24
- ONLY_INTERNET: External-only network
- YOZZU: 10.10.70.0/24

### Datastores:
- BVX-1: SSD-backed storage
- BVX-2: SSD-backed storage
- nfs-with-backup: NFS storage with backup capability

## Notes and Best Practices

### 1. Secrets Management:
- Use SOPS with AGE for secure secrets encryption
- Avoid committing sensitive files like secrets.env, SSH keys, and terraform.tfvars to version control

### 2. Automation:
- Let Cloud-Init handle network configuration to avoid Terraform customization blocks
- Regularly test and validate your templates to ensure compatibility

### 3. Troubleshooting:
- Use packer/packer.log for build logs
- Validate VMware credentials and network access using govc

### 4. Customization:
- Adjust VM resource allocations (CPU, memory) in terraform/variables.tf
- Support both DHCP and static IP configurations

### 5. Deployment Cleanliness:
- Clean network configurations after template creation to avoid conflicts
- Use provisioning scripts for advanced setup
