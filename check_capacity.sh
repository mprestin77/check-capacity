#!/usr/bin/env bash
#
# Query OCI Compute Capacity Reports for one or more regions and print the
# available instance count for the requested shape/configuration by AD.
#
# Usage:
#  ./check_capacity_formatted.sh <region> [<region> ...] <shape> <ocpus> <memory_gb>
#
# Example:
#  ./check_capacity_formatted.sh us-ashburn-1 us-chicago-1 VM.Standard.E5.Flex 1 16
#
# Optional environment variables:
#  OCI_TENANCY_OCID - tenancy to query (defaults to the tenancy used by the
#           original script)
#  OCI_CLI_AUTH   - OCI CLI auth mode (defaults to instance_principal)
#
# Physical/global AD mappings are tenancy-specific. This script has mappings
# for us-ashburn-1, us-chicago-1, us-phoenix-1, us-sanjose-1,
# eu-frankfurt-1, and uk-london-1.

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
DEFAULT_TENANCY_OCID="Enter your tenancy OCID"
OCI_TENANCY_OCID="${OCI_TENANCY_OCID:-$DEFAULT_TENANCY_OCID}"
OCI_AUTH="${OCI_CLI_AUTH:-api_key}"  # for instance principal set it to "${OCI_CLI_AUTH:-instance_principal}" 
REGION_TOTAL=0

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME <region> [<region> ...] <shape> <ocpus> <memory_gb>

Example:
 $SCRIPT_NAME us-ashburn-1 us-chicago-1 VM.Standard.E5.Flex 1 16
EOF
}

has_physical_ad_mapping() {
  case "$1" in
    us-ashburn-1|us-chicago-1|us-phoenix-1|us-sanjose-1|eu-frankfurt-1|uk-london-1)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

physical_ad_number() {
  local region="$1"
  local tenant_ad_number="$2"

  case "$region:$tenant_ad_number" in
    us-ashburn-1:1)  printf '1\n' ;;
    us-ashburn-1:2)  printf '2\n' ;;
    us-ashburn-1:3)  printf '3\n' ;;
    us-chicago-1:1)  printf '3\n' ;;
    us-chicago-1:2)  printf '1\n' ;;
    us-chicago-1:3)  printf '2\n' ;;
    us-phoenix-1:1)  printf '1\n' ;;
    us-phoenix-1:2)  printf '3\n' ;;
    us-phoenix-1:3)  printf '2\n' ;;
    us-sanjose-1:1)  printf '1\n' ;;
    eu-frankfurt-1:1) printf '2\n' ;;
    eu-frankfurt-1:2) printf '3\n' ;;
    eu-frankfurt-1:3) printf '1\n' ;;
    uk-london-1:1)  printf '1\n' ;;
    uk-london-1:2)  printf '3\n' ;;
    uk-london-1:3)  printf '2\n' ;;
    *) return 1 ;;
  esac
}

if [ "$#" -lt 4 ]; then
  usage >&2
  exit 1
fi

for required_command in oci jq; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Required command not found: $required_command" >&2
    exit 1
  fi
done

args=("$@")
argument_count=${#args[@]}
shape="${args[$((argument_count - 3))]}"
ocpus="${args[$((argument_count - 2))]}"
memory_gb="${args[$((argument_count - 1))]}"
regions=("${args[@]:0:$((argument_count - 3))}")

if ! [[ "$ocpus" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! [[ "$memory_gb" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "OCPUs and memory_gb must be numeric values." >&2
  exit 1
fi

shape_availabilities=$(jq -cn \
  --arg shape "$shape" \
  --argjson ocpus "$ocpus" \
  --argjson memory_gb "$memory_gb" \
  '[{
    instanceShape: $shape,
    instanceShapeConfig: {
      memoryInGBs: $memory_gb,
      ocpus: $ocpus
    }
  }]')

query_region() {
  local region="$1"
  local region_key
  local availability_domains_json
  local availability_domain
  local capacity_report
  local available_count
  local tenant_ad_number
  local physical_ad_number_value
  local region_label
  local total=0
  local ad_count=0
  local max_tenant_ad_number=0
  local max_physical_ad_number=0
  local mapping_available=false
  local mapping_complete=true
  local ad_number
  local -a tenant_ad_counts=()
  local -a physical_ad_counts=()

  region_key=$(printf '%s' "$region" | tr '[:upper:]' '[:lower:]')
  if has_physical_ad_mapping "$region_key"; then
    mapping_available=true
  fi

  if ! availability_domains_json=$(oci iam availability-domain list \
    --compartment-id "$OCI_TENANCY_OCID" \
    --region "$region" \
    --all \
    --output json \
    --auth "$OCI_AUTH"); then
    echo "Failed to list availability domains for $region." >&2
    return 1
  fi

  region_label=$(printf '%s' "$region_key" | tr '[:lower:]' '[:upper:]')
  printf '%s\n\n' "$region_label"

  while IFS= read -r availability_domain; do
    [ -n "$availability_domain" ] || continue
    ad_count=$((ad_count + 1))

    if ! capacity_report=$(oci compute compute-capacity-report create \
      --region "$region" \
      --availability-domain "$availability_domain" \
      --compartment-id "$OCI_TENANCY_OCID" \
      --shape-availabilities "$shape_availabilities" \
      --output json \
      --auth "$OCI_AUTH"); then
      echo "Failed to query capacity for $region / $availability_domain." >&2
      return 1
    fi

    available_count=$(jq -r '.data["shape-availabilities"][0]["available-count"]' <<<"$capacity_report")
    if ! [[ "$available_count" =~ ^[0-9]+$ ]]; then
      echo "Capacity count was not disclosed for $region / $availability_domain (available-count: $available_count)." >&2
      return 1
    fi

    # OCI names tenancy ADs like "gNfe:US-ASHBURN-AD-1".
    tenant_ad_number=$(sed -E 's/^.*-AD-([0-9]+)$/\1/' <<<"$availability_domain")
    if ! [[ "$tenant_ad_number" =~ ^[0-9]+$ ]]; then
      echo "Could not determine the tenant AD number from: $availability_domain" >&2
      return 1
    fi

    tenant_ad_counts[$tenant_ad_number]="$available_count"
    if [ "$tenant_ad_number" -gt "$max_tenant_ad_number" ]; then
      max_tenant_ad_number=$tenant_ad_number
    fi

    if [ "$mapping_available" = true ]; then
      if physical_ad_number_value=$(physical_ad_number "$region_key" "$tenant_ad_number"); then
        physical_ad_counts[$physical_ad_number_value]="$available_count"
        if [ "$physical_ad_number_value" -gt "$max_physical_ad_number" ]; then
          max_physical_ad_number=$physical_ad_number_value
        fi
      else
        mapping_complete=false
      fi
    fi

    total=$((total + available_count))
  done < <(jq -r '.data[].name' <<<"$availability_domains_json")

  if [ "$ad_count" -eq 0 ]; then
    echo "No availability domains were returned for $region." >&2
    return 1
  fi

  for ((ad_number = 1; ad_number <= max_tenant_ad_number; ad_number++)); do
    if [ "${tenant_ad_counts[$ad_number]+present}" = present ]; then
      printf 'Tenant AD%s - %s Instances\n' "$ad_number" "${tenant_ad_counts[$ad_number]}"
    fi
  done

  printf '\n'
  if [ "$mapping_available" = true ] && [ "$mapping_complete" = true ]; then
    for ((ad_number = 1; ad_number <= max_physical_ad_number; ad_number++)); do
      if [ "${physical_ad_counts[$ad_number]+present}" = present ]; then
        printf 'Physical AD%s - %s Instances\n' "$ad_number" "${physical_ad_counts[$ad_number]}"
      fi
    done
  elif [ "$mapping_available" = true ]; then
    printf 'Physical/global AD mapping is incomplete for %s; physical AD counts are not shown.\n' "$region_key"
  else
    printf 'Physical/global AD mapping is unavailable for %s; physical AD counts are not shown.\n' "$region_key"
  fi

  printf '\n'
  printf '%s Total: - %s Instances\n' "$region_label" "$total"
  REGION_TOTAL=$total
}

all_regions_total=0
for region in "${regions[@]}"; do
  query_region "$region"
  all_regions_total=$((all_regions_total + REGION_TOTAL))
  printf '\n'
done

if [ "${#regions[@]}" -gt 1 ]; then
  printf 'All Regions %s Total: - %s Instances\n' "$shape" "$all_regions_total"
fi
