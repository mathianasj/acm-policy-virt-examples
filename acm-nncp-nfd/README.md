# ACM-Managed OVS Bridge with NFD and PCI-Based NNCPs

Unified approach for deploying OVS bridges across heterogeneous server hardware using ACM policies, without hardcoding NIC interface names.

## Problem

Different server models use different NIC interface names (`eno1`, `enp3s0f0`, `ens192`, etc.) depending on vendor, model, firmware, and BIOS settings. A single `NodeNetworkConfigurationPolicy` (NNCP) that references a NIC by name will fail on nodes where the name differs.

## Solution

Combine two capabilities to eliminate interface name dependencies:

1. **Node Feature Discovery (NFD)** — automatically labels nodes with hardware identity (vendor, model) via DMI data from `/sys/devices/virtual/dmi/id/`
2. **nmstate `identifier: pci-address`** — matches NICs by PCI bus address instead of kernel interface name

Since nodes of the same server model share the same PCI topology, you get one NNCP per model that works across all units of that model regardless of OS-level naming.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  ACM Hub                                            │
│                                                     │
│  policy-nfd-operator          Install NFD           │
│        │                                            │
│        ▼ (depends on Compliant)                     │
│  policy-nfd-nic-profile-rules  NodeFeatureRules     │
│        │                       per server model     │
│        ▼ (depends on Compliant)                     │
│  policy-ovs-bridge-nncp        NNCPs using          │
│                                pci-address +        │
│                                nodeSelector          │
└─────────────────────────────────────────────────────┘
        │
        ▼  (PlacementBinding → PlacementRule)
┌───────────────────┐  ┌───────────────────┐
│  Managed Cluster  │  │  Managed Cluster  │
│  (Dell R640s)     │  │  (HPE DL380s)     │
│                   │  │                   │
│  NFD labels node: │  │  NFD labels node: │
│  nic-profile=     │  │  nic-profile=     │
│    dell-r640      │  │    hpe-dl380-gen10│
│                   │  │                   │
│  NNCP matches:    │  │  NNCP matches:    │
│  pci 0000:18:00.0 │  │  pci 0000:03:00.0│
│  → br-ex bridge   │  │  → br-ex bridge  │
└───────────────────┘  └───────────────────┘
```

## Files

| File | Description |
|------|-------------|
| `01-nfd-node-feature-rules.yaml` | Standalone NodeFeatureRules for direct apply (reference) |
| `02-nncp-dell-r640.yaml` | Standalone NNCP for Dell PowerEdge R640 |
| `02-nncp-dell-r650.yaml` | Standalone NNCP for Dell PowerEdge R650 |
| `02-nncp-hpe-dl380-gen10.yaml` | Standalone NNCP for HPE ProLiant DL380 Gen10 |
| `03-acm-policy.yaml` | Full ACM policy set wrapping all of the above |

The `01-*` and `02-*` files can be applied directly to a single cluster for testing. The `03-acm-policy.yaml` wraps everything for fleet-wide deployment via ACM.

## Prerequisites

- OpenShift 4.12+
- ACM 2.7+ (on hub cluster)
- kubernetes-nmstate operator installed on managed clusters (typically included with OpenShift)

## Setup Steps

### 1. Discover PCI Addresses Per Server Model

On one representative node of each server model, find the PCI address of the NIC you want in the OVS bridge:

```bash
# List all network interfaces
ip link show

# Find PCI address for a specific interface
ethtool -i eno1 | grep bus-info
# bus-info: 0000:18:00.0

# Or list all NICs with their PCI addresses
ls -l /sys/class/net/*/device | awk -F'/' '{print $(NF-1), $NF}'
```

### 2. Verify DMI Values

Confirm the DMI vendor and product name that NFD will read:

```bash
cat /sys/devices/virtual/dmi/id/sys_vendor
# Dell Inc.

cat /sys/devices/virtual/dmi/id/product_name
# PowerEdge R640
```

### 3. Update the Policies

Replace the placeholder PCI addresses in the NNCP files (marked with `# <-- replace`):

```yaml
- name: uplink0
  type: ethernet
  state: up
  identifier: pci-address
  pci-address: "0000:18:00.0"    # <-- your actual PCI address
```

Update the NodeFeatureRule `product_name` regex patterns if your DMI values differ from the examples.

### 4. Deploy via ACM

```bash
# Create the policy namespace if needed
oc create namespace open-cluster-management-policies

# Apply the ACM policies
oc apply -f 03-acm-policy.yaml
```

### 5. Verify

On a managed cluster:

```bash
# Check NFD labeled the nodes
oc get nodes --show-labels | grep nic-profile

# Check NNCP status
oc get nncp
oc get nnce  # per-node enactment status

# Check the bridge was created
oc debug node/<node-name> -- chroot /host ovs-vsctl show
```

## Adding a New Server Model

1. **Get hardware info** from a sample node:
   ```bash
   cat /sys/devices/virtual/dmi/id/sys_vendor
   cat /sys/devices/virtual/dmi/id/product_name
   ethtool -i <interface> | grep bus-info
   ```

2. **Add a NodeFeatureRule** entry in `03-acm-policy.yaml` under `policy-nfd-nic-profile-rules`:
   ```yaml
   - complianceType: musthave
     objectDefinition:
       apiVersion: nfd.k8s-sigs.io/v1alpha1
       kind: NodeFeatureRule
       metadata:
         name: nic-profile-<vendor>-<model>
       spec:
         rules:
           - name: "<vendor>-<model>"
             labels:
               "nic-profile": "<vendor>-<model>"
             matchFeatures:
               - feature: system.dmiid
                 matchExpressions:
                   sys_vendor: {op: In, value: ["<vendor string>"]}
                   product_name: {op: InRegexp, value: ["<product regex>"]}
   ```

3. **Add an NNCP ConfigurationPolicy** under `policy-ovs-bridge-nncp`:
   ```yaml
   - objectDefinition:
       apiVersion: policy.open-cluster-management.io/v1
       kind: ConfigurationPolicy
       metadata:
         name: nncp-ovs-bridge-<vendor>-<model>
       spec:
         remediationAction: enforce
         severity: medium
         object-templates:
           - complianceType: musthave
             objectDefinition:
               apiVersion: nmstate.io/v1
               kind: NodeNetworkConfigurationPolicy
               metadata:
                 name: ovs-bridge-<vendor>-<model>
               spec:
                 nodeSelector:
                   feature.node.kubernetes.io/nic-profile: <vendor>-<model>
                 desiredState:
                   interfaces:
                     - name: uplink0
                       type: ethernet
                       state: up
                       identifier: pci-address
                       pci-address: "<pci-address>"
                     - name: br-ex
                       type: ovs-bridge
                       state: up
                       bridge:
                         options:
                           stp: false
                         port:
                           - name: uplink0
                           - name: br-ex
                   ovs-db:
                     external_ids:
                       ovn-bridge-mappings: "physnet:br-ex"
   ```

## Key Concepts

### Why PCI Address Works

Linux predictable interface names (`enp3s0f0`) are derived from PCI topology — but the mapping rules vary by distro, firmware, and udev config. The PCI address itself (`0000:03:00.0`) is a hardware property that doesn't change. nmstate's `identifier: pci-address` bypasses the name entirely and targets the NIC at the hardware level.

### Why Not Regex on Interface Names

While NNCPs support interface name patterns, regex matching is fragile:
- `eno*` could match unintended onboard NICs
- Naming schemes change between RHEL/CoreOS versions
- A wrong match on a production NIC can take a node offline

PCI address matching is deterministic — it either matches the right NIC or nothing.

### NFD Label Flow

```
/sys/devices/virtual/dmi/id/sys_vendor    ──┐
/sys/devices/virtual/dmi/id/product_name  ──┤
                                            ▼
                                   NFD nfd-worker DaemonSet
                                            │
                                            ▼
                                   NodeFeatureRule match
                                            │
                                            ▼
                              Node label: nic-profile=dell-r640
                                            │
                                            ▼
                              NNCP nodeSelector matches
                                            │
                                            ▼
                              nmstate applies bridge config
                              using PCI address (not NIC name)
```

## Troubleshooting

### NFD Not Labeling Nodes

```bash
# Check NFD pods are running
oc get pods -n openshift-nfd

# Check NodeFeatureRule was created
oc get nodefeaturerules

# Check raw NFD features on a node
oc get nodefeature -n openshift-nfd <node-name> -o yaml | grep -A5 dmiid
```

### NNCP Not Applying

```bash
# Check NNCP status
oc get nncp <name> -o yaml

# Check per-node enactment
oc get nnce

# Check if nodeSelector matches any nodes
oc get nodes -l feature.node.kubernetes.io/nic-profile=dell-r640
```

### Wrong PCI Address

If the NNCP applies but no bridge appears, the PCI address may not match any NIC:

```bash
# On the node, list all PCI network devices
oc debug node/<node> -- chroot /host lspci | grep -i ethernet

# Map PCI address to interface name
oc debug node/<node> -- chroot /host ls -l /sys/class/net/*/device
```

### DMI product_name Contains Invalid Label Characters

Some product names contain spaces or special characters that break Kubernetes labels. The NodeFeatureRule approach avoids this — it matches on the raw DMI string but outputs a clean custom label (`nic-profile=dell-r640`) that you control.
