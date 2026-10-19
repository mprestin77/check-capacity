# OCI Compute capacity checker

`check_capacity.sh` queries OCI Compute Capacity Reports for one flexible VM
shape configuration across one or more OCI regions. It lists the capacity
available to the tenancy in each availability domain (AD), then prints a total
per region.

The script uses the OCI CLI operation:

```text
oci compute compute-capacity-report create
```

Oracle describes this report as the host capacity available for creating
instances in a specified AD. It is a point-in-time result, not a capacity
reservation or a launch guarantee.

## Prerequisites

- Bash 4 or later
- OCI CLI, authenticated for the tenancy
- `jq`
- The tenancy OCID
- The target regions must be subscribed in the tenancy
- The tenancy must be allowlisted to use the OCI Compute Capacity Report API.
  If it is not allowlisted, request enablement through the appropriate Oracle
  support or account channel before using this script.

The principal used by the OCI CLI requires these IAM policies:

```text
Allow group <group-name> to inspect compartments in tenancy
Allow group <group-name> to manage compute-capacity-reports in tenancy
```

`inspect compartments` permits `ListAvailabilityDomains`; `manage
compute-capacity-reports` permits `CreateComputeCapacityReport`.

## Configure authentication

The script defaults to API-key authentication:

```bash
OCI_CLI_AUTH=api_key
```

Set the tenancy OCID before running it. The script's built-in value is a
placeholder and must not be relied on.

```bash
export OCI_TENANCY_OCID='ocid1.tenancy.oc1..example'
```

For an instance principal, set the authentication mode for the same command:

```bash
OCI_TENANCY_OCID='ocid1.tenancy.oc1..example' \
OCI_CLI_AUTH=instance_principal \
./check_capacity.sh us-phoenix-1 VM.Standard.E6.Flex 2 32
```

## Usage

```text
./check_capacity.sh <region> [<region> ...] <shape> <ocpus> <memory_gb>
```

The final three arguments are always interpreted as the shape, OCPU count, and
memory in GB. All preceding arguments are OCI region identifiers.

Examples:

```bash
# Check a 1-OCPU, 16-GB E5 Flex VM in one region.
./check_capacity.sh us-ashburn-1 VM.Standard.E5.Flex 1 16

# Check the same configuration in two regions.
./check_capacity.sh \
  us-ashburn-1 us-chicago-1 \
  VM.Standard.E5.Flex 1 16

```

## Output

For each region, the script:

1. Retrieves the tenancy-specific AD names.
2. Requests one capacity report per AD for the supplied shape configuration.
3. Prints the `available-count` returned for each tenancy AD.
4. Prints a regional total, and an all-regions total when more than one region
   was requested.

Example format:

```text
US-PHOENIX-1

Tenant AD1 - 12 Instances
Tenant AD2 - 4 Instances
Tenant AD3 - 0 Instances

Physical AD1 - 12 Instances
Physical AD2 - 0 Instances
Physical AD3 - 4 Instances

US-PHOENIX-1 Total: - 16 Instances
```

`Tenant ADn` refers to the AD label assigned to this tenancy. OCI randomizes
AD labels between tenancies, so `AD-1` does not inherently identify the same
physical data center across different tenancies.

For six regions, the script additionally prints `Physical ADn` using a static
mapping: `us-ashburn-1`, `us-chicago-1`, `us-phoenix-1`, `us-sanjose-1`,
`eu-frankfurt-1`, and `uk-london-1`. Those mappings are only valid for the
tenancy for which they were established. Other regions deliberately show no
physical/global AD mapping.

## Important limitations

- A positive `available-count` is not a reservation. Capacity can change
  before an instance launch. Use a Compute Capacity Reservation when capacity
  must be guaranteed.
- The script requests capacity by AD, shape, OCPUs, and memory only. It does
  not test a cluster placement group (CPG), dedicated VM host, fault-domain
  constraint, image compatibility, subnet/IP availability, quotas, or other
  launch-time constraints.
- It does not specify a fault domain, so the report covers capacity across the
  AD's fault domains rather than a particular one.
- The selected OCPU and memory values must be valid for the shape. OCI may
  return an error or an unavailable status for unsupported combinations.
- The script currently reads `available-count`. If OCI returns an API error or
  does not disclose a numeric count, the script stops for that region.

## Troubleshooting

| Symptom | Likely cause / action |
|---|---|
| `NotAuthorizedOrNotFound` or `Authorization failed` | Confirm the two IAM policies above and the CLI authentication mode. |
| Compute Capacity Report API is unavailable or returns an access-related error despite correct IAM | Confirm that the tenancy is allowlisted for the OCI Compute Capacity Report API. |
| `InvalidParameter` | Verify the region, tenancy OCID, shape name, OCPU value, and memory value. |
| `Failed to list availability domains` | Verify the tenancy is subscribed to the region and that `OCI_TENANCY_OCID` is the root-compartment (tenancy) OCID. |
| `Failed to query capacity` | Confirm the CLI principal can create capacity reports and rerun the generated CLI call with `--debug` if needed. |
| Capacity report is positive but launch fails | Recheck capacity immediately and validate CPG, quotas, image/shape support, networking, and placement requirements. |

## References

- [OCI CLI: Create a Compute Capacity Report](https://docs.oracle.com/en-us/iaas/tools/oci-cli/latest/oci_cli_docs/cmdref/compute/compute-capacity-report/create.html)
- [OCI IAM policy reference: compute capacity reports](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/corepolicyreference.htm)
- [OCI regions and tenancy-specific AD names](https://docs.oracle.com/en-us/iaas/Content/General/Concepts/regions.htm)
