#!/bin/bash
#
# Discover NIC PCI addresses via the Redfish API (BMC/iDRAC/iLO).
# Outputs addresses in the SSSS:BB:DD.F format used by nmstate NNCPs.
#
# Supports both newer iDRAC (collection-based /PCIeDevices/) and older
# iDRAC (direct-link /PCIeDevice/ with BDF encoded in the resource ID).
#
# Usage:
#   ./get-nic-pci-redfish.sh <bmc-host> [username] [password]
#   ./get-nic-pci-redfish.sh <bmc-host> [username] [password] --vendor dell|hpe
#
# Environment variables (override arguments):
#   BMC_HOST, BMC_USER, BMC_PASS, BMC_VENDOR
#
# Examples:
#   ./get-nic-pci-redfish.sh 192.168.1.100 root calvin
#   ./get-nic-pci-redfish.sh ilo-host.example.com Administrator password --vendor hpe
#   BMC_HOST=10.0.0.1 BMC_USER=root BMC_PASS=secret ./get-nic-pci-redfish.sh

set -uo pipefail

BMC_HOST="${BMC_HOST:-${1:-}}"
BMC_USER="${BMC_USER:-${2:-root}}"
BMC_PASS="${BMC_PASS:-${3:-}}"
BMC_VENDOR="${BMC_VENDOR:-}"

if [[ -z "${BMC_HOST}" ]]; then
    echo "Usage: $0 <bmc-host> [username] [password] [--vendor dell|hpe]"
    echo ""
    echo "Environment variables: BMC_HOST, BMC_USER, BMC_PASS, BMC_VENDOR"
    exit 1
fi

if [[ -z "${BMC_PASS}" ]]; then
    echo -n "BMC password for ${BMC_USER}@${BMC_HOST}: "
    read -rs BMC_PASS
    echo
fi

# Parse --vendor flag
shift 3 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vendor) BMC_VENDOR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

CURL_OPTS=(-sk -u "${BMC_USER}:${BMC_PASS}" -H "Accept: application/json")
BASEURL="https://${BMC_HOST}"

redfish_get() {
    local response
    response=$(curl "${CURL_OPTS[@]}" "${BASEURL}${1}" 2>/dev/null) || true
    # Return empty object if the response is an error or empty
    if [[ -z "${response}" ]] || echo "${response}" | jq -e '.error' >/dev/null 2>&1; then
        echo "{}"
    else
        echo "${response}"
    fi
}

detect_vendor() {
    local service_root
    service_root=$(curl "${CURL_OPTS[@]}" "${BASEURL}/redfish/v1/" 2>/dev/null || true)
    if echo "${service_root}" | grep -qi "dell\|idrac"; then
        echo "dell"
    elif echo "${service_root}" | grep -qi "hpe\|ilo"; then
        echo "hpe"
    else
        echo "generic"
    fi
}

bdf_from_decimal() {
    local seg="${1:-0}" bus="${2:-0}" dev="${3:-0}" func="${4:-0}"
    printf "%04x:%02x:%02x.%x" "${seg}" "${bus}" "${dev}" "${func}"
}

# Parse BDF from a Dell PCIeFunction ID like "66-0-1" → bus=66 dev=0 func=1
bdf_from_id() {
    local id="$1"
    local bus dev func
    bus=$(echo "${id}" | cut -d'-' -f1)
    dev=$(echo "${id}" | cut -d'-' -f2)
    func=$(echo "${id}" | cut -d'-' -f3)
    if [[ -n "${bus}" && -n "${dev}" && -n "${func}" ]]; then
        bdf_from_decimal 0 "${bus}" "${dev}" "${func}"
    else
        echo "N/A"
    fi
}

try_get_mac() {
    local url="$1"
    [[ -z "${url}" || "${url}" == "null" ]] && echo "N/A" && return
    local resp
    resp=$(redfish_get "${url}")
    local mac
    mac=$(echo "${resp}" | jq -r '.MACAddress // .PermanentMACAddress // .Ethernet.MACAddress // empty' 2>/dev/null || true)
    if [[ -n "${mac}" && "${mac}" != "null" ]]; then
        echo "${mac}"
    else
        echo "N/A"
    fi
}

# Discover NICs via EthernetInterfaces (collection).
# On older Dell iDRAC, this may only list integrated NICs.
discover_via_ethernet_interfaces() {
    local system_id="$1"
    local ei_url="/redfish/v1/Systems/${system_id}/EthernetInterfaces"

    echo "Querying ethernet interfaces at ${ei_url} ..."
    local ei_json
    ei_json=$(redfish_get "${ei_url}")

    local member_urls
    member_urls=$(echo "${ei_json}" | jq -r '.Members[]."@odata.id" // empty' 2>/dev/null || true)

    if [[ -z "${member_urls}" ]]; then
        echo "  No EthernetInterfaces found."
        return 1
    fi

    echo ""
    echo "Ethernet Interfaces (from collection)"
    echo "======================================"
    echo ""
    printf "%-30s %-20s %-12s %s\n" "Interface ID" "MAC Address" "Speed (Mbps)" "Status"
    printf "%-30s %-20s %-12s %s\n" "------------" "-----------" "------------" "------"

    while IFS= read -r member_url; do
        [[ -z "${member_url}" ]] && continue
        local member_json
        member_json=$(redfish_get "${member_url}")

        local iface_id mac_addr speed_mbps link_status
        iface_id=$(echo "${member_json}" | jq -r '.Id // "Unknown"' 2>/dev/null || echo "Unknown")
        mac_addr=$(echo "${member_json}" | jq -r '.MACAddress // .PermanentMACAddress // "N/A"' 2>/dev/null || echo "N/A")
        speed_mbps=$(echo "${member_json}" | jq -r '.SpeedMbps // "N/A"' 2>/dev/null || echo "N/A")
        link_status=$(echo "${member_json}" | jq -r '.LinkStatus // .Status.State // "N/A"' 2>/dev/null || echo "N/A")

        printf "%-30s %-20s %-12s %s\n" "${iface_id}" "${mac_addr}" "${speed_mbps}" "${link_status}"
    done <<< "${member_urls}"
    echo ""
}

# Discover NICs via PCIe — handles both newer (collection) and older (direct-link) iDRAC.
#
# Newer iDRAC: /redfish/v1/Systems/{id}/PCIeDevices (collection with Members[])
#              /redfish/v1/Systems/{id}/PCIeDevices/{id}/PCIeFunctions/{id}
#              PCIeFunction has BusNumber, DeviceNumber, FunctionNumber fields
#
# Older iDRAC: System resource has .PCIeDevices[] and .PCIeFunctions[] arrays
#              /redfish/v1/Systems/{id}/PCIeDevice/{bus}-{dev} (singular)
#              /redfish/v1/Systems/{id}/PCIeFunction/{bus}-{dev}-{func} (singular)
#              BDF is encoded in the resource ID, no BusNumber fields
discover_via_pcie() {
    local system_id="$1"
    local system_url="/redfish/v1/Systems/${system_id}"

    # Try collection endpoint first (newer iDRAC)
    local collection_json
    collection_json=$(redfish_get "${system_url}/PCIeDevices")
    local collection_members
    collection_members=$(echo "${collection_json}" | jq -r '.Members[]."@odata.id" // empty' 2>/dev/null || true)

    if [[ -n "${collection_members}" ]]; then
        echo "Querying PCIe devices at ${system_url}/PCIeDevices ..."
        discover_pcie_from_urls "${collection_members}" "collection"
        return
    fi

    # Fall back to direct-link array on the System resource (older iDRAC)
    echo "PCIeDevices collection not available, reading from System resource..."
    local system_json
    system_json=$(redfish_get "${system_url}")

    local device_urls
    device_urls=$(echo "${system_json}" | jq -r '.PCIeDevices[]."@odata.id" // empty' 2>/dev/null || true)

    if [[ -z "${device_urls}" ]]; then
        echo "  No PCIe devices found."
        return 1
    fi

    discover_pcie_from_urls "${device_urls}" "direct-link"
}

discover_pcie_from_urls() {
    local device_urls="$1"
    local mode="$2"

    echo ""
    echo "NIC PCI Addresses"
    echo "================="
    echo ""
    printf "%-16s %-20s %-45s %s\n" "PCI Address" "MAC Address" "Device Name" "Device ID"
    printf "%-16s %-20s %-45s %s\n" "-----------" "-----------" "-----------" "---------"

    local found=0
    while IFS= read -r device_url; do
        [[ -z "${device_url}" ]] && continue
        local device_json
        device_json=$(redfish_get "${device_url}")
        local device_name device_id
        device_name=$(echo "${device_json}" | jq -r '.Name // "Unknown"' 2>/dev/null || echo "Unknown")
        device_id=$(echo "${device_json}" | jq -r '.Id // "Unknown"' 2>/dev/null || echo "Unknown")

        # Filter for network/ethernet devices
        local combined="${device_name} ${device_id}"
        local is_network
        is_network=$(echo "${combined}" | grep -ci "network\|ethernet\|nic\|net\|10g\|25g\|40g\|100g" || true)
        if [[ "${is_network}" -eq 0 ]]; then
            continue
        fi

        # Get PCIe function URLs from the device's Links
        local func_urls=""
        func_urls=$(echo "${device_json}" | jq -r '.Links.PCIeFunctions[]."@odata.id"' 2>/dev/null || true)

        # Fallback: try sub-collection (newer iDRAC)
        if [[ -z "${func_urls}" ]]; then
            func_urls=$(redfish_get "${device_url}/PCIeFunctions" | jq -r '.Members[]."@odata.id"' 2>/dev/null || true)
        fi

        if [[ -z "${func_urls}" ]]; then
            printf "%-16s %-20s %-45s %s\n" "(no BDF)" "N/A" "${device_name}" "${device_id}"
            found=$((found + 1))
            continue
        fi

        while IFS= read -r func_url; do
            [[ -z "${func_url}" ]] && continue
            local func_json
            func_json=$(redfish_get "${func_url}")

            local func_id dev_class pci_addr
            func_id=$(echo "${func_json}" | jq -r '.Id // ""' 2>/dev/null || true)
            dev_class=$(echo "${func_json}" | jq -r '.DeviceClass // "Unknown"' 2>/dev/null || echo "Unknown")

            if [[ "${dev_class}" != "NetworkController" ]] && [[ "${is_network}" -eq 0 ]]; then
                continue
            fi

            # Try explicit BDF fields first (newer iDRAC)
            local pci_bus pci_dev pci_func
            pci_bus=$(echo "${func_json}" | jq -r '.BusNumber // empty' 2>/dev/null || true)

            if [[ -n "${pci_bus}" && "${pci_bus}" != "null" ]]; then
                local pci_seg
                pci_seg=$(echo "${func_json}" | jq -r '.PciSegmentId // .SegmentNumber // 0' 2>/dev/null || echo 0)
                pci_dev=$(echo "${func_json}" | jq -r '.DeviceNumber // 0' 2>/dev/null || echo 0)
                pci_func=$(echo "${func_json}" | jq -r '.FunctionNumber // 0' 2>/dev/null || echo 0)
                [[ "${pci_seg}" == "null" ]] && pci_seg=0
                [[ "${pci_dev}" == "null" ]] && pci_dev=0
                [[ "${pci_func}" == "null" ]] && pci_func=0
                pci_addr=$(bdf_from_decimal "${pci_seg}" "${pci_bus}" "${pci_dev}" "${pci_func}")
            elif [[ -n "${func_id}" ]]; then
                # Parse BDF from ID format "bus-device-function" (older Dell iDRAC)
                pci_addr=$(bdf_from_id "${func_id}")
            else
                pci_addr="N/A"
            fi

            # Try to get MAC from linked EthernetInterface
            local mac_link mac_addr
            mac_link=$(echo "${func_json}" | jq -r '(.Links.EthernetInterfaces // [])[0]."@odata.id" // empty' 2>/dev/null || true)
            mac_addr=$(try_get_mac "${mac_link}")

            # Fallback: try NetworkDeviceFunctions link
            if [[ "${mac_addr}" == "N/A" ]]; then
                mac_link=$(echo "${func_json}" | jq -r '(.Links.NetworkDeviceFunctions // [])[0]."@odata.id" // empty' 2>/dev/null || true)
                mac_addr=$(try_get_mac "${mac_link}")
            fi

            printf "%-16s %-20s %-45s %s\n" "${pci_addr}" "${mac_addr}" "${device_name}" "${device_id}"
            found=$((found + 1))
        done <<< "${func_urls}"
    done <<< "${device_urls}"

    echo ""
    echo "Found ${found} network PCIe function(s)."

    if [[ "${found}" -gt 0 ]]; then
        echo ""
        echo "Use these PCI addresses in your NNCP:"
        echo '  - name: uplink0'
        echo '    type: ethernet'
        echo '    state: up'
        echo '    identifier: pci-address'
        echo '    pci-address: "<address-from-above>"'
    fi
}

discover_via_network_adapters() {
    local system_id="$1"
    local adapters_url="/redfish/v1/Systems/${system_id}/NetworkAdapters"

    echo "Querying network adapters at ${adapters_url} ..."
    local adapters_json
    adapters_json=$(redfish_get "${adapters_url}")

    local adapter_urls
    adapter_urls=$(echo "${adapters_json}" | jq -r '.Members[]."@odata.id" // empty' 2>/dev/null || true)

    if [[ -z "${adapter_urls}" ]]; then
        echo "  No network adapters found via NetworkAdapters endpoint."
        return 1
    fi

    echo ""
    echo "Network Adapters"
    echo "================"
    echo ""

    while IFS= read -r adapter_url; do
        [[ -z "${adapter_url}" ]] && continue
        local adapter_json
        adapter_json=$(redfish_get "${adapter_url}")
        local adapter_name adapter_id manufacturer model
        adapter_name=$(echo "${adapter_json}" | jq -r '.Name // "Unknown"' 2>/dev/null || echo "Unknown")
        adapter_id=$(echo "${adapter_json}" | jq -r '.Id // "Unknown"' 2>/dev/null || echo "Unknown")
        manufacturer=$(echo "${adapter_json}" | jq -r '.Manufacturer // "Unknown"' 2>/dev/null || echo "Unknown")
        model=$(echo "${adapter_json}" | jq -r '.Model // "Unknown"' 2>/dev/null || echo "Unknown")

        echo "Adapter: ${adapter_name} (${adapter_id})"
        echo "  Manufacturer: ${manufacturer}"
        echo "  Model: ${model}"

        # Extract controller PCIe info
        local controller_count
        controller_count=$(echo "${adapter_json}" | jq '.Controllers | length' 2>/dev/null || echo 0)

        local i
        for ((i = 0; i < controller_count; i++)); do
            local pcie_info
            pcie_info=$(echo "${adapter_json}" | jq ".Controllers[${i}].PCIeInterface // empty" 2>/dev/null || true)
            if [[ -n "${pcie_info}" && "${pcie_info}" != "null" ]]; then
                echo "  Controller ${i} PCIe: ${pcie_info}"
            fi
        done

        # List per-port MAC addresses from NetworkDeviceFunctions
        local ndf_url="${adapter_url}/NetworkDeviceFunctions"
        local ndf_json
        ndf_json=$(redfish_get "${ndf_url}")
        local ndf_urls
        ndf_urls=$(echo "${ndf_json}" | jq -r '.Members[]."@odata.id" // empty' 2>/dev/null || true)
        if [[ -n "${ndf_urls}" ]]; then
            echo "  Ports:"
            while IFS= read -r ndf_member_url; do
                [[ -z "${ndf_member_url}" ]] && continue
                local ndf_member_json ndf_mac ndf_id
                ndf_member_json=$(redfish_get "${ndf_member_url}")
                ndf_id=$(echo "${ndf_member_json}" | jq -r '.Id // "Unknown"' 2>/dev/null || echo "Unknown")
                ndf_mac=$(echo "${ndf_member_json}" | jq -r '.Ethernet.MACAddress // .MACAddress // "N/A"' 2>/dev/null || echo "N/A")
                echo "    ${ndf_id}: MAC ${ndf_mac}"
            done <<< "${ndf_urls}"
        fi
        echo ""
    done <<< "${adapter_urls}"
}

# Auto-detect vendor if not specified
if [[ -z "${BMC_VENDOR}" ]]; then
    echo "Auto-detecting BMC vendor..."
    BMC_VENDOR=$(detect_vendor)
    echo "Detected vendor: ${BMC_VENDOR}"
    echo ""
fi

# Determine the System ID based on vendor
case "${BMC_VENDOR}" in
    dell)
        SYSTEM_ID="System.Embedded.1"
        ;;
    hpe)
        SYSTEM_ID="1"
        ;;
    *)
        SYSTEM_ID=$(curl "${CURL_OPTS[@]}" "${BASEURL}/redfish/v1/Systems" 2>/dev/null | jq -r '.Members[0]."@odata.id"' 2>/dev/null | sed 's|.*/||')
        if [[ -z "${SYSTEM_ID}" ]]; then
            SYSTEM_ID="1"
        fi
        ;;
esac

echo "Using System ID: ${SYSTEM_ID}"
echo "BMC: ${BMC_HOST} (${BMC_VENDOR})"
echo ""

# EthernetInterfaces — may only list integrated NICs on older iDRAC
discover_via_ethernet_interfaces "${SYSTEM_ID}" || true

echo "---"
echo ""

# NetworkAdapters — adapter-level detail (manufacturer, model, per-port MACs)
discover_via_network_adapters "${SYSTEM_ID}" || true

echo "---"
echo ""

# PCIe discovery — finds ALL NICs including add-in cards
# Tries collection endpoint first, falls back to direct-link on System resource
discover_via_pcie "${SYSTEM_ID}" || true
