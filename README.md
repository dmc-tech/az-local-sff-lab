# Azure Local Small Form Factor (SFF) Three-Node Cluster

Deploy and provision an Azure Local Small Form Factor cluster using nested Hyper-V on an Azure VM — **1 node** (single-node SFF) or **3 nodes** (cluster). This project automates the full lifecycle: infrastructure provisioning with **Terraform** or **Bicep**, OS installation via an automated setup script, and voucher retrieval from the provisioned nodes.

For Microsoft's official product overview (ZTP, supported devices, and platform features), see [Overview of Small Form Factor Deployments of Azure Local (preview)](https://learn.microsoft.com/en-us/azure/azure-local/small-form-factor/small-form-factor-overview?view=azloc-2605).

For a side-by-side comparison, parameter mapping, and Bicep commands, see [`DEPLOYMENT.md`](DEPLOYMENT.md).

## Overview

Azure Local SFF nodes require a [zero-touch provisioning (ZTP)](https://learn.microsoft.com/en-us/azure/azure-local/small-form-factor/small-form-factor-overview?view=azloc-2605#features) workflow. This repo creates a test environment that simulates an SFF deployment by running nested VMs inside an Azure Hyper-V host. Set **`nested_vm_count`** (Terraform) or **`nestedVmCount`** (Bicep) to **1** for a single-node lab or **3** for a three-node cluster (default). The nested VMs boot from the official Azure Local installer ISO and receive IP addresses via DHCP, just as physical SFF hardware would on a real network.

### What gets deployed

**Terraform** or **Bicep** provisions the Azure infrastructure (same overall design; pick one tool):

- A Windows Server 2025 VM (`Standard_E32s_v5` — 32 vCPUs, 256 GB RAM) with nested virtualization support
- 1 TB premium data disk for VM storage
- Virtual network with NAT gateway for outbound internet
- Azure Bastion for secure RDP access (no public IP on the VM)
- Auto-shutdown schedule (19:00 GMT daily)
- A storage account to deliver provisioning scripts to the host

**setup.ps1** runs automatically on first boot and configures the Hyper-V host:

1. **Initialises the data disk** — brings the 1 TB disk online. A new disk is partitioned as GPT, given the next available drive letter (typically `E:`), and formatted as NTFS. An existing volume (from an earlier run, or a data disk reused after the VM was deleted) is used as-is with its current letter and contents.
2. **Creates directories** — sets up `<data drive>:\Hyper-V` for VM files, VHDs, and ISO images
3. **Downloads the OS image package** — fetches the Azure Local ZIP package (Terraform: `os_image_package_url`; Bicep: `osImagePackageUrl`), extracts `provision-os.iso`, and stages it for VM boot; the Configurator app URL is set the same way (`configurator_app_url` / `configuratorAppUrl`). See [Where to set the OS image package and Configurator app URLs](DEPLOYMENT.md#where-to-set-the-os-image-package-and-configurator-app-urls) in `DEPLOYMENT.md`.
4. **Configures NAT networking** — creates an internal Hyper-V switch (`NATSwitch`) with a `192.168.100.0/24` subnet and NAT for outbound connectivity
5. **Installs and configures DHCP** — sets up a DHCP scope (`192.168.100.100–200`) so the nested VMs receive IP addresses automatically
6. **Creates nested VMs** (`NestedVM-01` through `NestedVM-03` when count is 3, or `NestedVM-01` only when count is 1) — each with 8 vCPUs, 16 GB RAM, 500 GB dynamic VHDX, Generation 2, vTPM enabled, and MAC address spoofing on
7. **Attaches the ISO and boots** — mounts the installer ISO on each VM with DVD-first boot order and starts them

**Get-SffNodeVoucher.ps1** retrieves FDO voucher files from the provisioned nodes:

- Auto-discovers VM IPs from the DHCP scope (or accepts explicit IPs)
- Connects to each node via SSH and locates PEM voucher files
- Downloads vouchers to `C:\vouchers\<ip>\` on the host

## Deployment methods

| Approach | Summary |
|---|---|
| **Terraform** | Remote state-friendly; uses `*.tfvars` / `TF_VAR_*` and the workflow below. |
| **Bicep** | Native Azure IaC; deploy with `az deployment group create` and `main.bicep`. Full steps and parameter equivalences are in [`DEPLOYMENT.md`](DEPLOYMENT.md). |

The host behaviour after deploy (Custom Script Extension, `setup.ps1`, nested VMs, Bastion access) is the same for either path.

### Azure Local download URLs (OS package and Configurator)

To pin different **Azure Local** builds (OS composition ZIP / ISO source and **Configurator** app), set the variables before you deploy:

- **Terraform:** Your **`terraform.tfvars`** (copy from [`terraform.tfvars.example`](terraform.tfvars.example)) — `os_image_package_url`, `configurator_app_url`. Repository defaults are in [`variables.tf`](variables.tf) if you omit them from `*.tfvars`.
- **Bicep:** your parameter file from [`main.bicepparam.example`](main.bicepparam.example) — `osImagePackageUrl`, `configuratorAppUrl`, or the default `param` values at the top of [`main.bicep`](main.bicep).

Details and CLI override examples: [DEPLOYMENT.md — Where to set the OS image package and Configurator app URLs](DEPLOYMENT.md#where-to-set-the-os-image-package-and-configurator-app-urls).

## Prerequisites

- Azure CLI logged in (`az login`) with a subscription selected
- **Terraform path:** [Terraform](https://www.terraform.io/downloads) >= 1.0 (see `versions.tf`)
- **Bicep path:** [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) (`az bicep install`), used via `az deployment` commands ([`DEPLOYMENT.md`](DEPLOYMENT.md))
- Sufficient quota in the target region for `Standard_E32s_v5` and Azure Bastion

You only need the toolchain for the method you choose (Terraform alone, or Bicep alone, unless you maintain both).

## Remote State (recommended for Terraform)

State is stored in Azure Storage so it can be shared and protected. **Bicep deployments do not use this bootstrap**; they rely on Azure Resource Manager as the source of truth.

1. **Bootstrap** (once) — create the storage account and container:

```bash
cd bootstrap
copy terraform.tfvars.example terraform.tfvars
terraform init && terraform apply
cd ..
```

1. **Backend config** — copy `backend.hcl.example` to `backend.hcl` and fill in `resource_group_name`, `storage_account_name`, `container_name` from the bootstrap outputs, plus your chosen state file `key`.

2. **Initialise** the backend:

```bash
terraform init -reconfigure -backend-config=backend.hcl
```

See `bootstrap/README.md` for full details.

## Usage

### Terraform

1. **Configure variables:**

```bash
copy terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set admin_password (12+ chars, Azure complexity required)
# Optional: nested_vm_count = 1 for single-node SFF, or 3 (default) for a three-node cluster
# Optional: set os_image_package_url and configurator_app_url to target specific Azure Local builds (see DEPLOYMENT.md)
```

2. **Deploy:**

```bash
terraform init -reconfigure -backend-config=backend.hcl   # or just: terraform init
terraform plan
terraform apply
```

3. **Wait for provisioning.** Terraform installs the Hyper-V and DHCP roles, copies the scripts to `C:\Scripts\`, and reboots. On first logon (auto-logon is configured), `setup.ps1` runs automatically — it downloads the ISO, creates the VMs, and boots them from it.

4. **Connect via Azure Bastion.** In the Azure Portal: VM > Connect > Bastion. Sign in with the admin credentials from `terraform.tfvars`.

### Bicep

Deploy from the repository root after creating a resource group. Copy [`main.bicepparam.example`](main.bicepparam.example) to a parameter file you do not commit, set `adminPassword` and other parameters (`osImagePackageUrl` / `configuratorAppUrl` if you want to override the defaults in [`main.bicep`](main.bicep)), then run `az deployment group create` as documented in [`DEPLOYMENT.md`](DEPLOYMENT.md) (including optional password-from-shell examples). Outputs such as `vmPrivateIp` and `scriptsStorageAccountName` are available from the deployment. Connect via Bastion using the admin credentials you supplied to the deployment.

## After deployment (both methods)

1. **Retrieve vouchers.** The nested VMs boot the bootstrap loader, which generates an FDO voucher on each node. The voucher script can poll automatically. Start it right after `setup.ps1` finishes and it will wait for each node to produce its FDO PEM file, logging in as `edgeuser` / `Password1` (the defaults):

```powershell
# Automated polling (checks every 60s, up to 2 hours, password auth, trusts host keys on first use)
C:\Scripts\Get-SffNodeVoucher.ps1 -Wait -AutoTrustHostKeys
```

Or customise the interval and timeout, or use an SSH key instead of the password:

```powershell
C:\Scripts\Get-SffNodeVoucher.ps1 -Wait -AutoTrustHostKeys -PollIntervalSeconds 30 -TimeoutMinutes 90
C:\Scripts\Get-SffNodeVoucher.ps1 -Wait -SshKeyPath C:\Users\azureadmin\.ssh\id_rsa
```

One-shot mode is also available:

```powershell
C:\Scripts\Get-SffNodeVoucher.ps1
C:\Scripts\Get-SffNodeVoucher.ps1 -RemoteHosts @("192.168.100.100", "192.168.100.101", "192.168.100.102")
```

For unattended polling, set up SSH key-based auth first:

```powershell
ssh-keygen -t rsa -N '""' -f C:\Users\azureadmin\.ssh\id_rsa
# Then distribute the public key to each node once SSH is available
```

2. **Deploy SFF Linux from Azure.** The ISO the nested VMs boot is only a **bootstrap loader**. Use the vouchers from step 1 to provision the Small Form Factor devices in Azure ([Microsoft overview](https://learn.microsoft.com/en-us/azure/azure-local/small-form-factor/small-form-factor-overview)). Azure then deploys **SFF Linux** onto each node. Wait until Azure reports the deployment as complete for **every** node before you go on. Then download the private key (PEM) the portal provides for each machine and copy them all into **`C:\Scripts\keys\`** on the Hyper-V host. Keep the portal names, which share a prefix and end in the node number (for example `lab-sff-node-1-keyPair.pem` … `lab-sff-node-3-keyPair.pem`).

3. **K3s cluster (automated).** Once SFF Linux is deployed on all nodes, run one command from an elevated PowerShell on the Hyper-V host:

```powershell
C:\Scripts\Deploy-K3sCluster.ps1 -InstallKubectl
```

   The script first asks you to confirm that the SFF Linux deployment finished (pass `-SffLinuxDeployed` for unattended runs), because K3s installed on the bootstrap loader would be wiped by the deployment. It then:
   - discovers the node IPs and logs in to each node as `edgeuser` with its portal key. Key `n` is tried on `NestedVM-0n` first, then the others, in case the portal numbering differs. If `sudo` asks for a password, it uses `Password1`.
   - prepares the nodes, installs the K3s server on `NestedVM-01` and joins the others
   - waits for all nodes to be `Ready` and writes a kubeconfig to `C:\Scripts\k3s\kubeconfig`

   It is idempotent, so you can safely re-run it after a failure.

```powershell
$env:KUBECONFIG = 'C:\Scripts\k3s\kubeconfig'
C:\Scripts\k3s\bin\kubectl.exe get nodes -o wide
```

| Option | Effect |
|---|---|
| `-Topology HA` | All three nodes run as servers with embedded etcd, so the cluster survives the loss of any one node (default `ServerAgents`: 1 server + 2 agents) |
| `-K3sVersion v1.33.5+k3s1` | Pin a K3s release (default: stable channel) |
| `-EnableArc` | Connect the cluster to Azure Arc with Azure RBAC; add `-ArcServicePrincipal`/`-ArcTenantId` for unattended login, otherwise a device code is shown |
| `-Wait` | Poll until every node accepts SSH (e.g. while nodes reboot after the deployment) |
| `-SshKeyDirectory` / `-SshKeyPattern 'lab-sff-node-{0}-keyPair.pem'` / `-SshKeyPath` | Where the portal keys are, an exact per-node name, or one key for all nodes |
| `-AuthMode Password` / `-SshUser` / `-SshPassword` | Log in with a password instead of keys; override the user (`edgeuser`) or the `sudo` password (`Password1`) |
| `-NodeIPs` | Skip node discovery; the first IP becomes the first server |

   The full four-phase walkthrough (bootstrap loader, vouchers, Azure deployment, K3s), the manual fallback, and troubleshooting are in **`C:\Scripts\K3S-CLUSTER-SETUP.txt`** ([source](scripts/K3S-CLUSTER-SETUP.txt)). The nodes need outbound HTTPS to `get.k3s.io` and `github.com`.

   If `C:\Scripts` is missing files after you changed the repo, run **`terraform apply`** again so the Custom Script Extension re-runs (the extension timestamp changes when script content changes; the re-run reboots the host). For Bicep, also rebuild `main.json` (`az bicep build --file main.bicep`) if you deploy from the JSON. Check extension status under the VM → **Extensions** in the Azure portal, or logs under `C:\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\`.

## Azure Resources Created

The following table matches the **Terraform** variable names; Bicep uses the parameters listed in [`DEPLOYMENT.md`](DEPLOYMENT.md) (for example `vmName`, `adminUsername`).

| Resource | Details |
|---|---|
| Resource group | Per `resource_group_name` variable (Terraform) or the group you pass to `az deployment` (Bicep) |
| Virtual network | `10.0.0.0/16` |
| VM subnet | `10.0.1.0/24` with NAT gateway |
| Bastion subnet | `10.0.2.0/26` (`AzureBastionSubnet`) |
| NAT gateway | Standard SKU for outbound internet |
| Azure Bastion | Secure RDP access to the host |
| Windows Server VM | `Standard_E32s_v5`, Windows Server 2025 Datacenter |
| Data disk | 1 TB Premium LRS, attached as LUN 0 |
| Storage account | Holds provisioning scripts (`setup.ps1`, `Get-SffNodeVoucher.ps1`, `vm-bootstrap.ps1`, `Deploy-K3sCluster.ps1`, `k3s-node-prep.sh`, `k3s-install-server.sh`, `setup_k3s_arc.sh`, `k3s-join-agent.sh`, `bootstrap-k3s-agents.sh`, `K3S-CLUSTER-SETUP.txt`) |

## Optional: Virtual Network flow logs (Traffic Analytics) for Arc troubleshooting

If you set `enable_nsg_flow_logs = true` (Terraform) or `enableNsgFlowLogs = true` (Bicep), the template will deploy:

- An NSG on the Hyper-V host NIC (recommended for security; flow logs are collected at the VNet level)
- Network Watcher
- A storage account for virtual network flow logs
- (Optional) a Log Analytics workspace and Traffic Analytics (`enable_traffic_analytics` / `enableTrafficAnalytics`)

> Note: the nested Hyper-V VMs egress through the host (WinNAT). In Azure flow logs and Traffic Analytics, traffic will appear as coming from the **host VM private IP**, not from the nested `192.168.100.x` addresses.

### Ready-to-paste KQL (Log Analytics)

Run these in the Log Analytics workspace created when Traffic Analytics is enabled (`enable_traffic_analytics` / `enableTrafficAnalytics`).

Traffic Analytics for **Virtual Network flow logs** writes primarily to the `NTANetAnalytics` table.

**1) Show outbound denies from the Hyper-V host on TCP 443 (last 6 hours)**

Replace `<HOST_PRIVATE_IP>` with the Terraform output `vm_private_ip` or the Bicep output `vmPrivateIp` (e.g. `10.0.1.4`).

```kusto
NTANetAnalytics
| where SubType == "FlowLog"
| where TimeGenerated > ago(6h)
| where SrcIp == "<HOST_PRIVATE_IP>"
| where DestPort == 443
| summarize DeniedOutFlows = sum(DeniedOutFlows) by DestIp, L4Protocol, DestPort
| order by DeniedOutFlows desc
```

**2) Summarize top outbound destinations/ports from the host during registration attempts (last 2 hours)**

```kusto
NTANetAnalytics
| where SubType == "FlowLog"
| where TimeGenerated > ago(2h)
| where SrcIp == "<HOST_PRIVATE_IP>"
| summarize
    AllowedOutFlows = sum(AllowedOutFlows),
    DeniedOutFlows  = sum(DeniedOutFlows),
    BytesSrcToDest  = sum(BytesSrcToDest)
  by DestIp, DestPort, L4Protocol
| order by DeniedOutFlows desc, AllowedOutFlows desc
```

**3) Spot suspicious spikes on TCP 443 (possible egress/SNAT stress symptom)**

This buckets TCP 443 flows into 5-minute windows and highlights time periods with lots of denies relative to total flows.

```kusto
NTANetAnalytics
| where SubType == "FlowLog"
| where TimeGenerated > ago(2h)
| where SrcIp == "<HOST_PRIVATE_IP>"
| where DestPort == 443
| summarize
    Allowed = sum(AllowedOutFlows),
    Denied  = sum(DeniedOutFlows)
  by bin(TimeGenerated, 5m)
| extend Total = Allowed + Denied
| extend DenyRate = todouble(Denied) / iif(Total == 0, 1, Total)
| order by TimeGenerated asc
```

## Nested VM Configuration

| Setting | Value |
|---|---|
| Count | **1** or **3** (`nested_vm_count` / `nestedVmCount`; default 3) |
| Names | `NestedVM-01` (and `-02`, `-03` when count is 3) |
| Generation | 2 |
| vCPUs | 8 per VM |
| RAM | 16 GB static per VM |
| Disk | 500 GB dynamic VHDX |
| vTPM | Enabled (local key protector) |
| Network | `NATSwitch` — `192.168.100.0/24`, DHCP `100–200` |
| Boot | ISO first (Azure Local installer) |

## Scripts

| Script | Location on host | Purpose |
|---|---|---|
| `setup.ps1` | `C:\Scripts\setup.ps1` | Configures the Hyper-V host and provisions nested VMs (count from `nested_vm_count` / `nestedVmCount`) |
| `Get-SffNodeVoucher.ps1` | `C:\Scripts\Get-SffNodeVoucher.ps1` | Retrieves FDO voucher PEM files from the provisioned nodes via SSH |
| `Deploy-K3sCluster.ps1` | `C:\Scripts\Deploy-K3sCluster.ps1` | Builds the whole K3s cluster from the host over SSH (discovery, node prep, server/agent or HA install, kubeconfig, optional Arc) |
| `k3s-node-prep.sh` | `C:\Scripts\k3s-node-prep.sh` | Node prep: kernel modules, sysctl, firewall rules for cluster traffic, egress check |
| `k3s-install-server.sh` | `C:\Scripts\k3s-install-server.sh` | Installs a K3s server: first server (single or HA `cluster-init`) or an additional HA server |
| `setup_k3s_arc.sh` | `C:\Scripts\setup_k3s_arc.sh` | Connects the cluster to Azure Arc and configures Azure RBAC (device code or service principal) |
| `k3s-join-agent.sh` | `C:\Scripts\k3s-join-agent.sh` | Installs K3s agent on a worker with `INSTALL_K3S_SKIP_SELINUX_RPM=true` |
| `bootstrap-k3s-agents.sh` | `C:\Scripts\bootstrap-k3s-agents.sh` | Manual alternative: from the K3s server node, SSHes to the workers and runs the join script |
| `vm-bootstrap.ps1` | `C:\Scripts\vm-bootstrap.ps1` | Hyper-V host bootstrap (also run once by Custom Script Extension) |
| `K3S-CLUSTER-SETUP.txt` | `C:\Scripts\K3S-CLUSTER-SETUP.txt` | Step-by-step K3s cluster setup instructions (open in Notepad on the host) |

Logs from `setup.ps1` are written to `C:\Scripts\setup.log`.

## Notes

- Do not commit `terraform.tfvars` or Bicep parameter files that contain secrets — the admin password must stay out of source control. The `.gitignore` excludes common cases by default.
- The auto-shutdown schedule powers down the VM at 19:00 GMT daily to reduce costs.
- `setup.ps1` is idempotent — it writes a completion flag (`C:\Scripts\.setup-completed`) and skips on subsequent runs.
