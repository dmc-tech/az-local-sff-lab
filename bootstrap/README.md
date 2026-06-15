# Terraform state backend bootstrap

Creates the Azure storage account and container used to store Terraform state for the main Hyper-V host configuration.

If you deploy the host with **Bicep** instead of Terraform, you do not need this bootstrap—see [`DEPLOYMENT.md`](../DEPLOYMENT.md) in the repo root.

## Prerequisites

- Terraform >= 1.0
- Azure CLI logged in (`az login`) with subscription set

## Usage

1. From this directory, copy variables and apply:

   ```bash
   copy terraform.tfvars.example terraform.tfvars
   terraform init
   terraform plan
   terraform apply
   ```

2. Note the outputs: `storage_account_name`, `resource_group_name`, `container_name`, `state_file_key`.

3. In the **parent directory** (main Hyper-V host Terraform), create `backend.hcl` using the output values:

   ```hcl
   resource_group_name  = "<resource_group_name output>"
   storage_account_name = "<storage_account_name output>"
   container_name       = "<container_name output>"
   key                  = "hyperv-host.tfstate"   # or any state file name you prefer
   ```

4. From the parent directory, initialise the backend:

   ```bash
   terraform init -reconfigure -backend-config=backend.hcl
   ```

## Variables

- **state_file_key** – Name of the state blob (parameterised). Change this if you want a different state file name; use the same value in the main module’s `backend.hcl` as `key`.

## One-time setup

Bootstrap only needs to be run once per environment. The same storage account and container can hold multiple state files by using different `key` values in each backend config.
