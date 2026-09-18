# Azure infrastructure for a Multi-Tier Geospatial Platform

![Azure](https://img.shields.io/badge/Azure-Networking-blue)
![Terraform](https://img.shields.io/badge/Terraform-IaC-purple)
![Ansible](https://img.shields.io/badge/Ansible-Config%20Mgmt-red)
![Status](https://img.shields.io/badge/Status-Complete-green)

A self-directed lab to build the underlying infrastructure for a multi-tier geospatial platform.

This project started as an attempt to build a multi-tier ArcGIS Enterprise environment in Azure. I ended up narrowing the scope to the infrastructure underneath a geospatial platform: segmented networking, private Linux VMs, secure administrative access, Terraform provisioning, and Ansible configuration management. The application layer was intentionally left out of scope; project ends at the infrastructure and operating-system configuration layer.

## Project Goals

- Build a realistic multi-tier Azure environment instead of another isolated cloud exercise
- Get hands-on with Terraform for provisioning and managing Azure infrastructure
- Use Ansible to configure and harden Linux VMs after deployment
- Practice network segmentation, private addressing, NSGs, SSH jump-host access, and outbound NAT
- Build infrastructure similar to what could sit underneath a geospatial platform

## Architecture Overview

The environment is split into three tiers, each isolated in its own subnet:

| Tier | Subnet | CIDR | Intended Role |
|------|--------|------|---------------|
| Web | `snet-portal` | 10.0.1.0/24 | Front-end / reverse proxy tier |
| Application | `snet-server` | 10.0.2.0/24 | Geospatial application services |
| Database | `snet-datastore` | 10.0.3.0/24 | PostgreSQL/PostGIS-style data tier |
| Management | `snet-jumpbox` | 10.0.4.0/24 | Administrative jumpbox |

All three subnets sit inside a single VNet (`vnet-arcgis-lab`, 10.0.0.0/16),
segmented by function rather than left flat. This mirrors the general shape
of the on-prem/cloud hybrid ArcGIS environment I support professionally,
where a remote Data Store feeds an ArcGIS Server site consumed by both
Portal and direct desktop (ArcGIS Pro) connections.

## Network Security Design

Each application tier was placed in its own subnet with a dedicated NSG.

The initial design included ArcGIS-specific rules based on the original
ArcGIS Enterprise deployment plan. As the project scope shifted toward
the underlying infrastructure, the focus became:

- Administrative access through a dedicated jumpbox
- No public IPs on the three private RHEL VMs
- SSH access to private hosts through ProxyJump
- Separate subnets for web, application, database, and management tiers
- Host-level firewalling with firewalld
- SELinux enforcing on RHEL hosts
- NAT Gateway for outbound package and update access

### nsg-portal
| Priority | Source | Port | Purpose |
|---|---|---|---|
| 100 | Admin IP | 3389/TCP | Administrative access |
| 110 | Admin IP | 443/TCP | Reserved for intended Portal HTTPS traffic |

### nsg-server
| Priority | Source | Port | Purpose |
|---|---|---|---|
| 100 | Admin IP | 3389/TCP | Administrative access |
| 110 | snet-portal (10.0.1.0/24) | 6443/TCP | Reserved for intended Portal–Server federation |
| 120 | snet-portal (10.0.1.0/24) | 6080/TCP | Reserved for intended Portal–Server communication |
| 130 | Admin IP | 6443/TCP | Reserved for intended direct server access |

### nsg-datastore
| Priority | Source | Port | Purpose |
|---|---|---|---|
| 100 | Admin IP | 3389/TCP | Administrative access |
| 110 | snet-server (10.0.2.0/24) | 2443/TCP | Reserved for intended data-store communication |
| 120 | snet-server (10.0.2.0/24) | 9876/TCP | Reserved for intended relational-store traffic |
| 130 | snet-server (10.0.2.0/24) | 9840/TCP | Reserved for intended cache traffic |
| 140–150 | snet-server (10.0.2.0/24) | 9820, 9850/TCP | Reserved for intended data-store traffic |
| 160–180 | snet-server (10.0.2.0/24) | 45671–45672, 25672, 44369/TCP | Reserved for intended service communication |

**Design note:** Azure's default AllowVnetInBound rule still permits traffic between subnets within the VNet. I created the explicit tier-to-tier NSG rules above as part of the original design, but I did not complete the final hardening step of removing broad VNet-internal access. As a result, the environment demonstrates the intended segmentation and rule design, but does not enforce strict east-west isolation between tiers.

## Infrastructure as Code (Terraform)

After building Phase 1 manually through the Azure Portal to establish a
working understanding of the architecture, the same networking
infrastructure was brought under Terraform management using `terraform
import` rather than a clean rebuild. 
I did it this way because that's how it actually works in the real world 
where you inherit existing infrastructure and there's no such thing as a clean start. 

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

## Jumpbox Provisioning and Hardening

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

## Configuration Management with Ansible

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

**A true "did I just break this entire thing?" moment**

I was converting SSH hardening that I manually configured into Ansible so the configuration would be repeatable. Somewhere in the process I misspelled `PasswordAuthentication` and `KbdInteractiveAuthentication` (It's entirely possible I misspelled it again, here, who knows) in the SSH configuration. Ansible put that bad config onto the jumpbox. `sshd` could no longer start correctly and eventually hi the `systemd Start request repeated too quickly` state. Then, I hit the real consequence: **I couldn't SSH into the jumpbox machine**, this was the primary access to the other three machines. Because the RHEL servers didn't have public IPs, intentionally so the jumpbox was the only access point, losing the jumpbox cut off normal administration to the entire private side of the lab. At this point ** I had to consider if I needed to tear down the entire lab and restart ** to fix the broken path - after having spent so much time building and hardening this thing, one typo had potentially locked me out of my own infrastructure. 

Instead of rebuilding, I learned that **Azure** gives you an **out-of-band control-plane** with  `az vm run-command`. This doesn't depend on SSH working. It was effectively MY "in case this, break glass" type of tool in this situation. I used it to inspect `systemctl status sshd`, check the firewall, and establish that this wasn't an NSG/routing problem, the SSH service itself was broken. I ran `sshd -t` through that channel and finally exposed the malformed configuration options. I corrected the live file with `sed`, validated it again, and tried bringing SSH back. I hit a **second** wall: `/run/sshd` was missing. Even after fixing the original typo, the daemon still wouldn't come up cleanly. I was able to fix this with the same out-of-band channel and restarted the service.

Once I was able to SSH login again, finally, I still wasn't finished. I corrected the Ansible source so the next run wouldn't put the bad config right back, I corrected the Ansible source/template so another run would not cause the same problem. 

**First Takeaway:** automation amplifies mistakes. The same thing that lets Ansible apply a good config consistently can apply a bad config just as consistently. 
**Second Takeaway:** I learned why out-of-band management matters.
**Third Takeaway:** Validate. Validate. Validate...before replacing a known-good config....sooner rather than later. 


## Completed Scope

- [x] Designed a segmented Azure VNet with separate application, data, and management subnets
- [x] Created tier-specific NSGs based on the original ArcGIS Enterprise design
- [x] Imported the existing Azure networking environment into Terraform
- [x] Provisioned an Ubuntu jumpbox as the only public administrative entry point
- [x] Provisioned three private RHEL VMs for the web, application, and database tiers
- [x] Configured SSH `ProxyJump` access with separate key pairs
- [x] Added NAT Gateway egress so private hosts could reach package repositories without public IPs
- [x] Hardened the jumpbox with UFW, Fail2ban, and OpenSSH controls
- [x] Hardened the RHEL hosts with firewalld, SELinux, key-only SSH, and jumpbox-only administrative access
- [x] Brought Linux configuration under Ansible management
- [x] Verified Ansible idempotence across the managed hosts
- [x] Tested out-of-band Azure recovery after an SSH configuration failure

### Intentionally left out of scope

The ArcGIS Enterprise / GeoServer / PostGIS application layer was not deployed. The project stops at the Azure infrastructure, Linux host configuration, and administrative-access layer.

