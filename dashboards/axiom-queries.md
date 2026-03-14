# Axiom Queries & Dashboard Setup

All queries use [APL (Axiom Processing Language)](https://axiom.co/docs/apl/introduction).
Replace dataset names with your own (e.g., `cjp-firewalla` → `firewalla`).

## Ad-hoc queries (Query tab)

### Top 20 most-queried domains

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend domain = tostring(parsed["query"])
| where domain != "" and domain != "*"
| summarize query_count = count() by domain
| order by query_count desc
| take 20
```

### Per-device activity (with device names)

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_ip = tostring(parsed["id.orig_h"]), domain = tostring(parsed["query"])
| where domain != "" and domain != "*"
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | distinct ipv4, name
) on $left.source_ip == $right.ipv4
| extend device = coalesce(name, source_ip)
| summarize unique_domains = dcount(domain), total_queries = count() by device
| order by total_queries desc
```

### Domains visited by a specific device IP

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_ip = tostring(parsed["id.orig_h"]), domain = tostring(parsed["query"])
| where source_ip == "192.168.139.31"
| where domain != "" and domain != "*"
| summarize query_count = count() by domain
| order by query_count desc
| take 20
```

### Blocked connections

```kusto
['firewalla']
| where log_source == "firewalla_acl"
```

### Inspect raw Zeek JSON structure

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| project parsed
| take 1
```

## Dashboard setup

### Step 1: Create Filter Bar

Create a new dashboard → Add element → **Filter Bar**

- Filter type: **Select**
- Filter name: `Device`
- Filter ID: `_device`
- Value: **Query**
- Query:

```kusto
['firewalla-devices']
| where record_type == "device_lookup"
| distinct name, ipv4
| project key=name, value=ipv4
| sort by key asc
```

This populates the dropdown with device names, but the selected _value_ is the
device's IP address — so chart queries can filter directly on IP without joins.

### Step 2: Top Domains table

Add element → **Table** → APL mode:

```kusto
declare query_parameters(_device:string = "");
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_ip = tostring(parsed["id.orig_h"]), domain = tostring(parsed["query"])
| where source_ip == _device
| where domain != "" and domain != "*"
| summarize query_count = count() by domain
| order by query_count desc
```

### Step 3: DNS Activity Over Time

Add element → **Time Series** → APL mode:

```kusto
declare query_parameters(_device:string = "");
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_ip = tostring(parsed["id.orig_h"])
| where source_ip == _device
| summarize queries = count() by bin_auto(_time)
```

### Step 4: Raw DNS Events

Add element → **Log Stream** → APL mode:

```kusto
declare query_parameters(_device:string = "");
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_ip = tostring(parsed["id.orig_h"]), domain = tostring(parsed["query"])
| where source_ip == _device
| where domain != "" and domain != "*"
| project _time, domain, source_ip
```

## Notes on Zeek JSON field names

Zeek uses dotted field names like `id.orig_h`. In APL, use bracket notation:

```kusto
| extend source_ip = tostring(parsed["id.orig_h"])
```

Not:

```kusto
| extend source_ip = tostring(parsed.id.orig_h)  // WRONG — treats as nested path
```

## Group-based dashboards

These queries require the `group` field in your devices dataset, which is
populated by the updated `device_lookup_export.sh` reading from `device_groups.json`.

### DNS volume by group (pie chart)

Shows which device groups generate the most DNS traffic.

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_ip = tostring(parsed["id.orig_h"])
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | distinct ipv4, group
) on $left.source_ip == $right.ipv4
| extend device_group = coalesce(group, "Unknown")
| summarize query_count = count() by device_group
| order by query_count desc
```

### Group activity over time (stacked time series)

Shows the household rhythm — work spikes weekday mornings, entertainment
ramps up evenings, IoT is constant.

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_ip = tostring(parsed["id.orig_h"])
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | distinct ipv4, group
) on $left.source_ip == $right.ipv4
| extend device_group = coalesce(group, "Unknown")
| summarize queries = count() by bin_auto(_time), device_group
```

### Group dashboard with filter bar

Add a **Filter Bar** with a group selector:

- Filter name: `Group`
- Filter ID: `_group`
- Value: **Query**

```kusto
['firewalla-devices']
| where record_type == "device_lookup"
| distinct group
| project key=group, value=group
| sort by key asc
```

Then use this in chart queries:

```kusto
declare query_parameters(_group:string = "");
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_ip = tostring(parsed["id.orig_h"]), domain = tostring(parsed["query"])
| where domain != "" and domain != "*"
| join kind=inner (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | where group == _group
    | distinct ipv4, name
) on $left.source_ip == $right.ipv4
| summarize query_count = count() by name, domain
| order by query_count desc
```

### IoT Accountability Board

Shows exactly what your smart home devices are phoning home to.

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_ip = tostring(parsed["id.orig_h"]), domain = tostring(parsed["query"])
| where domain != "" and domain != "*"
| join kind=inner (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | where group == "IoT" or group == "Smart Home"
    | distinct ipv4, name
) on $left.source_ip == $right.ipv4
| summarize query_count = count() by name, domain
| order by query_count desc
```

### New Domain Radar

Finds domains queried for the first time today by any device. A sudden
burst of new domains from an IoT device is a strong compromise signal.

```kusto
let today_domains =
['firewalla']
| where log_source == "zeek_dns"
| where _time > ago(24h)
| extend parsed = parse_json(log)
| extend source_ip = tostring(parsed["id.orig_h"]), domain = tostring(parsed["query"])
| where domain != "" and domain != "*"
| distinct source_ip, domain;
let historical_domains =
['firewalla']
| where log_source == "zeek_dns"
| where _time > ago(30d) and _time < ago(24h)
| extend parsed = parse_json(log)
| extend domain = tostring(parse_json(log)["query"])
| where domain != "" and domain != "*"
| distinct domain;
today_domains
| join kind=leftanti historical_domains on domain
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | distinct ipv4, name, group
) on $left.source_ip == $right.ipv4
| summarize new_domains = dcount(domain), domains = make_set(domain) by name, group
| order by new_domains desc
```

### Kids Activity Summary

Quick view of what the kids' devices are doing — great for screen time conversations.

```kusto
declare query_parameters(_group:string = "Kids");
['firewalla']
| where log_source == "zeek_dns"
| extend parsed = parse_json(log)
| extend source_ip = tostring(parsed["id.orig_h"]), domain = tostring(parsed["query"])
| where domain != "" and domain != "*"
| join kind=inner (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | where group == _group or group == "Kids-TVs"
    | distinct ipv4, name
) on $left.source_ip == $right.ipv4
| summarize query_count = count() by name, domain
| order by query_count desc
```

