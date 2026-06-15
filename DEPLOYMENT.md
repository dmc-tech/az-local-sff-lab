# Deployment instructions

This repository provisions a Windows Server Hyper-V lab host in Azure (virtual network, Azure Bastion, NAT gateway, optional Virtual Network flow logs, storage for provisioning scripts, and a Custom Script extension). You can deploy with **Terraform** or **Bicep**. The [README](README.md) gives a shorter overview of both options; this file is the detailed reference (commands, parameter mapping, extension re-run).

## Prerequisites

- An Azure subscription and permission to create resources (for example Contributor on a resource group).
- **Terraform**: Terraform `>= 1.0`, Azure CLI authenticated (`az login`), and the `azurerm` + `random` providers (see `versions.tf`).
- **Bicep**: [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) and [Bicep CLI](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install) (`az bicep install`). Run commands from the repository root so paths such as `scripts/setup.ps1` and `arm-templates/vm-shutdown.arm.json` resolve correctly.

## Common inputs

| Setting | Terraform (`variables.tf`) | Bicep (`main.bicep`) |
|--------|----------------------------|----------------------|
| Region | `location` (default `UK South`) | `location` (defaults to resource group location) |
| Admin user / password | `admin_username`, `admin_password` | `adminUsername`, `adminPassword` |
| VM name | `vm_name` (≤ 15 characters) | `vmName` |
| Nested VM prefix | `nested_vm_prefix` | `nestedVmPrefix` |
| Data disk size (GB) | `data_disk_size_gb` | `dataDiskSizeGb` |
| OS / Configurator URLs | `os_image_package_url`, `configurator_app_url` | `osImagePackageUrl`, `configuratorAppUrl` |
| Flow logs | `enable_nsg_flow_logs`, `enable_traffic_analytics`, retention vars | `enableNsgFlowLogs`, `enableTrafficAnalytics`, `nsgFlowLogsRetentionDays`, `logAnalyticsRetentionDays` |
| Tags | `tags` | `tags` (default includes `ManagedBy: 'Bicep'`) |

### Where to set the OS image package and Configurator app URLs

These values are passed through the Custom Script Extension into `vm-bootstrap.ps1` / `setup.ps1` (Azure Local ZIP or ISO URL, and Configurator `.msix` / `.exe` URL). Point them at the builds you want before `terraform apply` or `az deployment group create`.

| Tool | Prefer | Fallback (defaults baked into the repo) |
|------|--------|----------------------------------------|
| **Terraform** | [`terraform.tfvars`](terraform.tfvars.example) — set `os_image_package_url` and `configurator_app_url` (copy from [`terraform.tfvars.example`](terraform.tfvars.example)). | [`variables.tf`](variables.tf) — blocks `variable "os_image_package_url"` and `variable "configurator_app_url"` if you do not override them in `*.tfvars`. |
| **Bicep** | Your `.bicepparam` file (copy from [`main.bicepparam.example`](main.bicepparam.example)) — add `param osImagePackageUrl = '...'` and `param configuratorAppUrl = '...'`. You can instead pass overrides on the CLI, for example `--parameters osImagePackageUrl="<url>" configuratorAppUrl="<url>"`. | [`main.bicep`](main.bicep) — parameters `osImagePackageUrl` and `configuratorAppUrl` near the top of the file carry the default URLs if you do not override them. |

Provisioning scripts include **`scripts/setup.ps1`**, **`scripts/Get-SffNodeVoucher.ps1`**, **`scripts/vm-bootstrap.ps1`**, **`scripts/setup-k3s-arc.sh`**, **`scripts/k3s-join-agent.sh`**, **`scripts/bootstrap-k3s-agents.sh`**, and **`scripts/K3S-CLUSTER-SETUP.txt`**. Terraform uploads them from disk; Bicep embeds them at compile time via `loadTextContent`, then a deployment script uploads them to the scripts storage account before the VM extension runs. After the Custom Script Extension runs, copies land in **`C:\Scripts\`** on the Hyper-V host (including **`K3S-CLUSTER-SETUP.txt`** for K3s steps).

## Option A: Terraform

1. **Optional — remote state bootstrap**  
   If you use the Azure backend, run the bootstrap stack once (`bootstrap/`), then configure the root module backend per `backend.hcl.example`.

2. **Configure variables**  
   Export `TF_VAR_admin_password` (or use a `*.tfvars` file you do not commit) and adjust other variables as needed. Set **`os_image_package_url`** and **`configurator_app_url`** in `terraform.tfvars` (or rely on defaults in `variables.tf`); details are in [Where to set the OS image package and Configurator app URLs](#where-to-set-the-os-image-package-and-configurator-app-urls) above.

3. **Deploy**

   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

4. **Outputs**  
   See `outputs.tf` (resource group, VM id/name, private IP, Bastion id, NAT public IP, scripts storage account, flow log flags, and so on).

## Option B: Bicep

Run these from the **repository root** so `main.bicep`, `scripts/`, `modules/`, and `arm-templates/` resolve correctly.

### Deploy (resource group scope)

1. **Create a resource group** (example name and region; change as needed):

   ```bash
   az group create --name rg-hyperv-host-uks --location uksouth
   ```

2. **Deploy with a parameter file** (edit `main.bicepparam` first, or use a copy you do not commit — set **`osImagePackageUrl`** / **`configuratorAppUrl`** there if you need to override defaults in `main.bicep`; see [Where to set the OS image package and Configurator app URLs](#where-to-set-the-os-image-package-and-configurator-app-urls) above):

   ```bash
   az deployment group create \
     --resource-group rg-hyperv-host-uks \
     --template-file main.bicep \
     --parameters main.bicepparam
   ```

3. **Deploy with the password only from the shell** (no secret in the param file; add URL overrides on the same command if needed, e.g. `osImagePackageUrl=<url> configuratorAppUrl=<url>`):

   **Linux / macOS / WSL (bash):**

   ```bash
   az deployment group create \
     --resource-group rg-hyperv-host-uks \
     --template-file main.bicep \
     --parameters adminPassword="$ADMIN_PASSWORD"
   ```

   **Windows (PowerShell):**

   ```powershell
   az deployment group create `
     --resource-group rg-hyperv-host-uks `
     --template-file main.bicep `
     --parameters adminPassword="$env:ADMIN_PASSWORD"
   ```

   Set the variable before running (bash: `export ADMIN_PASSWORD='...'`; PowerShell: `$env:ADMIN_PASSWORD = '...'`).

4. **Optional: name the deployment** (easier to find in the portal and when querying outputs):

   ```bash
   az deployment group create \
     --name "deploy-hyperv-$(date +%Y%m%d%H%M%S)" \
     --resource-group rg-hyperv-host-uks \
     --template-file main.bicep \
     --parameters main.bicepparam
   ```

   On PowerShell you can pass any string, for example `--name deploy-hyperv-20260414120000`.

### Validate / compile (optional)

```bash
az bicep build --file main.bicep
```

### Outputs

Use the same **deployment name** you passed to `--name` on `az deployment group create` (if any); otherwise use the deployment name shown in the command output or in the Azure portal.

```bash
az deployment group show \
  --resource-group rg-hyperv-host-uks \
  --name <deploymentName> \
  --query properties.outputs
```

Template outputs mirror the Terraform outputs where applicable (`vmId`, `vmPrivateIp`, `bastionHostId`, `natGatewayPublicIp`, `scriptsStorageAccountName`, flow log–related values, and `hypervReadyNote`).

### Bicep-only artifacts

- **`modules/vm-shutdown.bicep`** — Invokes the shutdown ARM template (the linter prefers a module over an inline `Microsoft.Resources/deployments` resource in `main.bicep`; the module file keeps one targeted suppression for the same pattern).
- **`modules/flow-log-traffic-analytics.bicep`** — Deploys the Log Analytics workspace and the flow log with Traffic Analytics together so analyzer rules do not flag nullable workspace references.
- **`arm-templates/vm-shutdown.arm.json`** — Nested ARM template used to create the DevTestLab auto-shutdown schedule. Azure requires a compound resource name that is awkward to express as a first-class Bicep resource; the JSON template matches the behavior of `azurerm_dev_test_global_vm_shutdown_schedule` in `main.tf`.

### Forcing the Custom Script extension to re-run

- **Terraform**: Changing the setup script changes `filemd5`, which updates the extension `timestamp`.
- **Bicep**: Increase `customScriptTimestamp` and redeploy, or change script content (length affects the derived timestamp). See the `customScriptTimestamp` parameter in `main.bicep`.

## After deployment

- Connect to the host with **Azure Bastion** (RDP). The template output `hypervReadyNote` reminds you that a reboot may be needed after Hyper-V installation and first-run automation.
- Outbound traffic from the workload subnet uses the **NAT gateway** public IP (`natGatewayPublicIp` / `nat_gateway_public_ip`).
- If you enabled flow logs, data lands in the dedicated storage account; Traffic Analytics uses the Log Analytics workspace when `enableTrafficAnalytics` / `enable_traffic_analytics` is true.

## Choosing an approach

| | Terraform | Bicep |
|---|-----------|--------|
| State / workflow | Typical team choice when you already standardize on Terraform and remote state | Native Azure IaC; pairs well with `az deployment` and Azure Policy |
| Secret handling | `TF_VAR_*`, `.tfvars`, Azure backend | `.bicepparam`, `--parameters`, Key Vault references (advanced) |
| Script upload | Blob upload via provider | `loadTextContent` + `deploymentScripts` seed + SAS for the extension |

Use whichever fits your environment; both templates aim to model the same core architecture as `main.tf`.
