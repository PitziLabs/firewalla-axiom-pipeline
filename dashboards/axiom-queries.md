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
