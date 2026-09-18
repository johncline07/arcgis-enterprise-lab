# Multi-Tier ArcGIS Enterprise Deployment on Azure

![Azure](https://img.shields.io/badge/Azure-Networking-blue)
![Terraform](https://img.shields.io/badge/Terraform-IaC-purple)
![Ansible](https://img.shields.io/badge/Ansible-Config%20Mgmt-red)
![Status](https://img.shields.io/badge/Status-Complete-green)

A self-directed lab to build the underlying infrastructure for a multi-tier geospatial platform.

This project started as an attempt to build a multi-tier ArcGIS Enterprise environment in Azure. I ended up narrowing the scope to the infrastructure underneath a geospatial platform: segmented networking, private Linux VMs, secure administrative access, Terraform provisioning, and Ansible configuration management. The application layer was intentionally left out of scope; project ends at the infrastructure and operating-system configuration layer.

## Project Goals

- Demonstrate hands-on provisioning and configuration of ArcGIS Enterprise
  infrastructure, beyond day-to-day GIS data support work
- Apply cloud networking and security fundamentals (VNets, subnets, NSGs) to
  a real multi-tier application architecture
- Build a foundation for ongoing Azure certification study (AZ-104) using a
  concrete, non-trivial project rather than isolated exercises

## Architecture Overview

The environment is split into three tiers, each isolated in its own subnet:

| Tier | Subnet | CIDR | Role |
|------|--------|------|------|
| Portal | `snet-portal` | 10.0.1.0/24 | User-facing web UI, authentication, content management |
| Server | `snet-server` | 10.0.2.0/24 | Hosts and serves map/feature services; federates with Portal |
| Data Store | `snet-datastore` | 10.0.3.0/24 | Backing relational store for hosted content |

All three subnets sit inside a single VNet (`vnet-arcgis-lab`, 10.0.0.0/16),
segmented by function rather than left flat. This mirrors the general shape
of the on-prem/cloud hybrid ArcGIS environment I support professionally,
where a remote Data Store feeds an ArcGIS Server site consumed by both
Portal and direct desktop (ArcGIS Pro) connections.

## Network Security Design

Each subnet has a dedicated Network Security Group (NSG) scoped to the
minimum inbound access required for that tier, based on Esri's documented
ArcGIS Enterprise port requirements (https://enterprise.arcgis.com).
Rather than opening broad ranges or relying on trial and error, each rule
maps directly to a specific, documented ArcGIS Enterprise communication
requirement.

### nsg-portal
| Priority | Source | Port | Purpose |
|---|---|---|---|
| 100 | Admin IP | 3389/TCP | Remote administration |
| 110 | Admin IP | 443/TCP | HTTPS access to Portal web UI |

### nsg-server
| Priority | Source | Port | Purpose |
|---|---|---|---|
| 100 | Admin IP | 3389/TCP | Remote administration |
| 110 | snet-portal (10.0.1.0/24) | 6443/TCP | Portal–Server federation (HTTPS) |
| 120 | snet-portal (10.0.1.0/24) | 6080/TCP | Portal–Server federation (HTTP) |
| 130 | Admin IP | 6443/TCP | Direct ArcGIS Pro connection to Server |

### nsg-datastore
| Priority | Source | Port | Purpose |
|---|---|---|---|
| 100 | Admin IP | 3389/TCP | Remote administration |
| 110 | snet-server (10.0.2.0/24) | 2443/TCP | Data Store deployment communication |
| 120 | snet-server (10.0.2.0/24) | 9876/TCP | Relational store ↔ hosting server |
| 130 | snet-server (10.0.2.0/24) | 9840/TCP | In-memory cache database |
| 140–150 | snet-server (10.0.2.0/24) | 9820, 9850/TCP | Data Store machine-to-machine communication |
| 160–180 | snet-server (10.0.2.0/24) | 45671–45672, 25672, 44369/TCP | Service webhook communication |

**Design note:** Azure's default `AllowVnetInBound` rule currently permits
all traffic between subnets within the VNet regardless of the explicit rules
above. This was a deliberate, known trade-off for this phase, to validate
the application stack works end-to-end before layering on stricter
VNet-internal enforcement. Tightening this — replacing the default
any-to-any internal rule with the explicit tier-to-tier rules above as the
sole permitted paths — is planned as a hardening pass once the full stack
is deployed and functional.

## Phase 1.5: Infrastructure as Code (Terraform)

After building Phase 1 manually through the Azure Portal to establish a
working understanding of the architecture, the same networking
infrastructure was brought under Terraform management using `terraform
import` rather than a clean rebuild — a deliberately more realistic
exercise, since real-world environments are far more often *inherited*
into IaC than built from a blank slate.

**Project structure:**
```
terraform/
├── providers.tf        # Provider and Terraform block configuration
├── variables.tf         # Reusable input variables
├── terraform.tfvars      # Local variable values (gitignored — contains admin IP)
├── network.tf            # Resource group, VNet, subnets
├── nsg.tf                # Network Security Groups and inbound rules
├── associations.tf        # Subnet-to-NSG associations
└── .gitignore
```

**What was imported and codified:**
- Resource group, VNet, and all three subnets
- All three NSGs, including all 15 inbound security rules, written as
  inline `security_rule` blocks
- All three subnet-to-NSG associations

**Notable issues encountered and resolved:**
- **Forced replacement on subnets**: the AzureRM provider defaults
  `default_outbound_access_enabled` to `true` when the attribute is
  omitted from configuration, while the existing subnets had it set to
  `false`. Since this attribute cannot be changed in place, Terraform
  initially planned to destroy and recreate all three subnets on import.
  Resolved by explicitly setting the attribute to match the real deployed
  state before importing.
- **IP address formatting mismatch**: Azure's Portal stores a
  single-host NSG rule source as a bare IP address (e.g.
  `admin_ip`), while Terraform's AzureRM provider represents it in
  explicit CIDR notation (`admin_ip`). Both are functionally
  identical, but required one `terraform apply` per NSG to normalize the
  stored format and eliminate a persistent, harmless diff.
- **Provider naming typos**: several early `terraform init`/`plan`
  errors traced back to typos in resource type names and the
  `required_providers` local key (e.g. `azurem` instead of `azurerm`,
  `azurerm_virtual_nework` instead of `azurerm_virtual_network`) —
  resolved by reading Terraform's error output carefully rather than
  assuming the config was correct.

This phase reinforced the distinction between Terraform **state**
(populated by `terraform import`, reflecting real-world resource data)
and Terraform **configuration** (`.tf` files, written manually to
describe desired state) — two separate concerns that `terraform plan`
reconciles, rather than import automatically generating code.


## Phase 2: Jumpbox Provisioning and Hardening

A dedicated Ubuntu 22.04 LTS jumpbox was provisioned in Terraform to provide
the only public administrative entry point into the environment. The ArcGIS
Enterprise application VMs will remain on private subnets without public IP
addresses and will be reached through the jumpbox with SSH `ProxyJump`.

### Jumpbox provisioning

The jumpbox is defined as an `azurerm_linux_virtual_machine` with:

- A dedicated network interface and public IP address
- An NSG associated with the jumpbox subnet
- TCP/22 allowed only from the administrative public IP (`/32`)
- SSH public-key authentication
- Password authentication disabled in the Azure VM resource
- A separate administrative account, `azureadmin`
- Ubuntu Server 22.04 LTS using the Azure-optimized kernel

A separate SSH key pair is used for the jumpbox. A different key pair will be
used for the private RHEL ArcGIS Enterprise VMs so that compromise of one key
does not automatically grant access to every Linux host.

### SSH hardening

After deployment, the effective OpenSSH configuration was verified with
`sshd -T` rather than relying only on individual configuration files. A
dedicated drop-in file was created at:

```text
/etc/ssh/sshd_config.d/99-hardening.conf
```

The following controls were applied:

```text
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding local
AllowUsers azureadmin
```

`AllowTcpForwarding local` is intentionally retained because the jumpbox must
support SSH tunneling and `ProxyJump` connections to the private RHEL VMs.
Remote forwarding is not required. Agent forwarding is disabled, and private
keys remain on the administrator workstation rather than being copied to the
jumpbox.

Every SSH change was validated with `sshd -t`, followed by an SSH service
reload and a second-session login test before the original session was closed.

### Network and host firewall controls

Administrative SSH is restricted at two layers:

1. The Azure NSG permits TCP/22 only from the administrative public IP.
2. UFW denies inbound traffic by default and permits TCP/22 only from the same
   administrative IP.

This provides defense in depth while preserving the NSG as the primary Azure
network boundary. Because the administrative public IP may change, both the
Terraform variable and UFW rule must be updated when necessary.

The active listening sockets were reviewed with `ss -lntup`. Only expected
services were present: SSH, local DNS resolution, DHCP client traffic, and
local Chrony time synchronization.

### Patching and brute-force protection

The VM was fully updated with `apt full-upgrade`, rebooted into the current
Azure kernel, and verified with `uname -r`.

Ubuntu unattended upgrades were confirmed to be enabled and active. Both
`apt-daily.timer` and `apt-daily-upgrade.timer` are scheduled. Security and
eligible kernel updates may be installed automatically, but a reboot is still
required before a newly installed kernel becomes active.

Fail2ban was installed and the `sshd` jail enabled. It provides a secondary
response to repeated SSH authentication failures. It is not treated as a
replacement for the source-restricted NSG and UFW rules.

### Reproducibility and the cloud-init decision

The hardening steps were initially performed manually so each control could be
verified individually. They were then translated into a reusable Terraform
cloud-init template:

```text
terraform/cloud-init/jumpbox.yaml.tftpl
```

The template installs Fail2ban and UFW, writes the SSH hardening drop-in,
enables the required services, and renders the UFW source rule from the same
`admin_ip` Terraform variable used by the NSG.

Adding the template to the already-imported VM through `custom_data` caused
Terraform to plan a forced replacement of the jumpbox because custom data is a
provisioning-time property. That replacement was intentionally rejected. The
current VM remains in place, and the cloud-init template is retained as the
first-boot recipe for a future intentional rebuild.

## Configuration Management Decision: Introducing Ansible

Terraform manages the Azure infrastructure lifecycle, but it does not inspect
or continuously enforce the operating-system state inside a VM. Cloud-init is
useful for first-boot configuration, but Terraform only manages the cloud-init
input; it does not detect later drift in packages, services, firewall rules, or
files inside Ubuntu or RHEL.

Ansible is therefore being introduced as the configuration-management layer.

The intended separation of responsibilities is:

| Tool | Responsibility |
|---|---|
| Terraform | Resource group, VNet, subnets, NSGs, associations, NICs, public/private IPs, VMs, disks, and Azure resource lifecycle |
| Cloud-init | Minimal first-boot bootstrap for newly created Linux VMs |
| Ansible | Ongoing package state, SSH hardening, host firewalls, users, services, OS prerequisites, and later ArcGIS Enterprise installation/configuration |

The existing jumpbox will be the first host brought under Ansible management.
This provides a controlled starting point because its desired configuration is
already known and manually verified. The initial Ansible playbooks should
reproduce that state and then complete a second run with no changes, confirming
idempotence.

The private RHEL VMs will use the same security objectives but not identical
implementation. For example:

- Ubuntu uses `apt` and UFW; RHEL uses `dnf` and `firewalld`.
- The jumpbox retains local TCP forwarding for `ProxyJump`; the private RHEL
  hosts should normally disable TCP forwarding.
- Fail2ban is valuable on the public jumpbox but may be optional on private-only
  hosts.
- SELinux should remain enforcing on the RHEL ArcGIS hosts unless an
  application requirement is documented and addressed deliberately.
- ArcGIS ports will be opened only on the specific RHEL role that requires
  them.

Ansible will run from the administrator workstation. It will connect directly
to the jumpbox and use the jumpbox as the SSH proxy for the private RHEL hosts.
The separate private keys will remain on the workstation.

## Phase 2.5: Configuration Management with Ansible

The jumpbox's manually-verified hardening state was reproduced as an Ansible
role, `roles/hardening/`, structured as:

```text
ansible/
├── ansible.cfg
├── inventory/
│   ├── lab.yml
│   └── group_vars/
│       └── jumpboxes.yml       # admin_ip and other host-group variables
├── playbooks/
│   └── configure.yml
└── roles/
    └── hardening/
        ├── tasks/main.yml
        ├── handlers/main.yml
        └── templates/
            ├── 99-hardening.conf.j2
            └── sshd.local.j2
```

**What the role manages:**
- UFW and Fail2ban package installation
- The SSH hardening drop-in (`/etc/ssh/sshd_config.d/99-hardening.conf`),
  rendered from a Jinja2 template so the allowed admin user is parameterized
  rather than hardcoded
- SSH config validation (`sshd -t`) before a reload is triggered, and only
  when the rendered file actually changes
- UFW default-deny-incoming / allow-outgoing policy, with SSH allowed only
  from the administrative IP
- A Fail2ban `sshd` jail, deployed from its own template
- Ensuring both services are enabled and running

**Idempotence was verified directly**, per the original goal for this phase:
running `ansible-playbook -i inventory/lab.yml playbooks/configure.yml` twice
in sequence produced `changed=0` on the second run across all ten tasks, with
the SSH-validation task correctly reported as `skipped` (its `when` condition
depends on the template task actually changing something).

### Incident: SSH service failure during hardening rollout

While iterating on the SSH hardening template, a typo shipped in the rendered
config (`PasswordAuthetication` / `KbdInteractiveAuthetication`, both missing
an "n"). `sshd`'s post-reload validation caught the malformed options, and the
service entered a crash-loop (`Start request repeated too quickly`), taking
SSH access to the jumpbox down entirely — the only administrative path into
the environment.

**Diagnosis and recovery used Azure's out-of-band `az vm run-command`
channel**, which executes scripts on the VM through the Azure control plane
rather than over SSH, and was the only available access path once sshd was
down:

1. `systemctl status sshd` and `ufw status verbose` confirmed sshd was
   failed/crash-looping rather than a network/NSG problem
2. `sshd -t` run directly via `run-command` surfaced the exact bad
   configuration options and line numbers
3. The typo was corrected on the live host with a targeted `sed` replacement,
   validated again with `sshd -t`, and the service was restarted
4. A secondary issue — a missing `/run/sshd` privilege-separation directory,
   normally created at boot — was found and fixed the same way before sshd
   would start cleanly
5. Normal SSH access was confirmed restored before re-running the corrected
   Ansible role

The template file was corrected locally (and converted from CRLF to LF line
endings, which had made the typo harder to visually verify) so the fix is
version-controlled rather than only existing as a manual live patch. A stray
UFW rule from an earlier, differently-typo'd admin IP was also found and
removed during recovery.

**Takeaway:** the role's existing `sshd -t` validation step is correct in
principle, but it validates the file *after* it has already been written to
disk and *right before* a reload — it does not prevent a bad config from
reaching the host in the first place. A useful future refinement would be
validating the rendered template's content before it is deployed, rather
than only after.


## Status

- [x] Phase 1: VNet, subnet, and NSG design
- [x] Phase 1.5: Infrastructure codified and verified in Terraform
- [x] Phase 2: Jumpbox provisioning and Linux hardening
  - [x] Ubuntu jumpbox provisioned in Terraform
  - [x] Jumpbox manually hardened and validated
  - [x] Reusable cloud-init template created
  - [x] Jumpbox brought under Ansible management
- [x] Phase 2.5: Private RHEL VM provisioning
  - [x] Private RHEL VMs provisioned for web, GeoServer, and PostGIS tiers
  - [x] Private NICs assigned static IPs
  - [x] SSH access confirmed through jumpbox using ProxyJump
  - [x] NAT Gateway added for outbound RHUI/package access
- [x] Phase 2.6: RHEL baseline hardening with Ansible
  - [x] Baseline RHEL hardening role created
  - [x] firewalld enabled
  - [x] SELinux enforcing
  - [x] SSH root login and password authentication disabled
  - [x] SSH restricted to jumpbox source
  - [x] Idempotence confirmed across all three private RHEL VMs

