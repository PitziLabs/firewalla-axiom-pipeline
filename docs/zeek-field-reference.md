# Zeek JSON Field Reference

This reference covers the JSON fields emitted by Zeek on Firewalla firmware for
`dns.log` and `conn.log`. All fields are present in the raw `log` string that
Fluent Bit ships to Axiom — parse it with `parse_json(log)` in APL queries.

## Field name gotchas

### Bracket notation is required in APL

Zeek uses dotted field names like `id.orig_h`. In APL, the dot is a nested-path
separator, so `parsed.id.orig_h` silently returns `null` instead of the value
you want. Always use bracket notation:

```kusto
| extend source_ip = tostring(parsed["id.orig_h"])   // correct
| extend source_ip = tostring(parsed.id.orig_h)       // wrong — returns null
```

### MAC addresses are lowercased by Zeek

Zeek writes MAC addresses in lowercase (e.g., `e8:4c:4a:db:9c:e8`). Firewalla's
Redis device inventory stores them in uppercase (`E8:4C:4A:DB:9C:E8`). The
`device_lookup_export.sh` script normalises Redis MACs to lowercase before
writing to the `firewalla-devices` dataset, so joins work correctly.

### Integer fields arrive as strings in some contexts

Fields like `qtype`, `rcode`, `orig_bytes`, and `resp_bytes` are numeric in
Zeek's JSON but APL's `parse_json()` may return them as strings depending on
the Axiom ingest path. Use explicit casts:

```kusto
| extend orig_bytes = tolong(parsed["orig_bytes"])
| extend qtype      = toint(parsed["qtype"])
```

### Boolean fields

Boolean Zeek fields (`AA`, `TC`, `RD`, `RA`, `rejected`) are emitted as JSON
`true`/`false`. In APL, cast with `tobool()`:

```kusto
| extend recursion_desired = tobool(parsed["RD"])
```

### Absent vs. null fields

Zeek omits fields that have no value rather than writing `null`. Always use
`isnotempty()` or `isnotnull()` guards when a field may be absent:

```kusto
| where isnotempty(tostring(parsed["query"]))
```

---

## dns.log fields

Each row in `dns.log` represents a single DNS query/response pair observed on
the network.

| Field | Type | Description |
|-------|------|-------------|
| `ts` | float | Unix epoch timestamp of the first DNS packet. Fluent Bit maps this to `_time` in Axiom. |
| `uid` | string | Unique connection identifier (e.g., `CnQevD3eFtgYtgY7Cc`). Links related log entries across log types. |
| `id.orig_h` | string | Source (client) IP address — the device that made the DNS query. Requires bracket notation. |
| `id.orig_p` | int | Source port of the DNS client (typically ephemeral, e.g., `54321`). |
| `id.resp_h` | string | Destination IP address — the DNS server that received the query (e.g., `8.8.8.8`). |
| `id.resp_p` | int | Destination port — always `53` for standard DNS. |
| `proto` | string | Transport protocol: `udp` (most DNS) or `tcp` (large responses, zone transfers). |
| `trans_id` | int | DNS transaction ID (0–65535). Matches query to response within a session. |
| `rtt` | float | Round-trip time in seconds from query sent to response received. Absent if no response was seen. |
| `query` | string | The domain name that was queried (e.g., `api.example.com`). This is the primary field for domain analysis. |
| `qclass` | int | Numeric DNS query class. Almost always `1` (Internet). |
| `qclass_name` | string | Human-readable query class: `C_INTERNET` for class 1. |
| `qtype` | int | Numeric DNS query type (e.g., `1` = A, `28` = AAAA, `5` = CNAME). |
| `qtype_name` | string | Human-readable query type: `A`, `AAAA`, `CNAME`, `MX`, `TXT`, `PTR`, `SRV`, `NS`, etc. |
| `rcode` | int | Numeric DNS response code. `0` = NOERROR, `3` = NXDOMAIN, `2` = SERVFAIL. |
| `rcode_name` | string | Human-readable response code: `NOERROR`, `NXDOMAIN`, `SERVFAIL`, `REFUSED`, etc. |
| `AA` | bool | Authoritative Answer flag — `true` if the response came directly from the zone's authoritative server. |
| `TC` | bool | Truncation flag — `true` if the response was truncated and the client should retry over TCP. |
| `RD` | bool | Recursion Desired flag — `true` if the client asked the server to resolve recursively (almost always `true`). |
| `RA` | bool | Recursion Available flag — `true` if the server supports recursive queries. |
| `Z` | int | Reserved bits in the DNS header. Should always be `0`; non-zero values may indicate malformed packets. |
| `answers` | array | Array of resource record strings in the DNS response (e.g., `["93.184.216.34"]`, `["api.cdn.example.com", "203.0.113.1"]`). Empty array if no answer section. |
| `TTLs` | array | Array of TTL values (in seconds) for each answer record. Parallel array to `answers`. |
| `rejected` | bool | `true` if Zeek's internal DNS analysis determined the response was rejected or invalid. |
| `orig_l2_addr` | string | Source MAC address of the querying device (e.g., `e8:4c:4a:db:9c:e8`). **Key field for device joins** — more reliable than IP because it works for both IPv4 and IPv6 clients. |
| `resp_l2_addr` | string | Destination MAC address — typically the router/gateway MAC for upstream DNS queries. |

### Example dns.log event (raw JSON)

```json
{
  "ts": 1741737600.123456,
  "uid": "CnQevD3eFtgYtgY7Cc",
  "id.orig_h": "192.168.1.42",
  "id.orig_p": 54321,
  "id.resp_h": "8.8.8.8",
  "id.resp_p": 53,
  "proto": "udp",
  "trans_id": 12345,
  "rtt": 0.012,
  "query": "api.example.com",
  "qclass": 1,
  "qclass_name": "C_INTERNET",
  "qtype": 1,
  "qtype_name": "A",
  "rcode": 0,
  "rcode_name": "NOERROR",
  "AA": false,
  "TC": false,
  "RD": true,
  "RA": true,
  "Z": 0,
  "answers": ["93.184.216.34"],
  "TTLs": [3600.0],
  "rejected": false,
  "orig_l2_addr": "e8:4c:4a:db:9c:e8",
  "resp_l2_addr": "dc:a6:32:01:23:45"
}
```

---

## conn.log fields

Each row in `conn.log` represents a completed network connection (TCP session,
UDP flow, or ICMP exchange). This log is used for bandwidth analysis and tying
DNS queries to actual traffic.

| Field | Type | Description |
|-------|------|-------------|
| `ts` | float | Unix epoch timestamp of the first packet in the connection. |
| `uid` | string | Unique connection identifier. Matches `uid` values in other Zeek log types (e.g., `ssl.log`, `http.log`) for the same connection. |
| `id.orig_h` | string | Source (originator) IP address. |
| `id.orig_p` | int | Source port of the originator. |
| `id.resp_h` | string | Destination (responder) IP address. |
| `id.resp_p` | int | Destination port (e.g., `443` for HTTPS, `80` for HTTP, `53` for DNS). |
| `proto` | string | Transport protocol: `tcp`, `udp`, or `icmp`. |
| `service` | string | Application-layer protocol detected by Zeek (e.g., `dns`, `ssl`, `http`, `dhcp`). Absent if Zeek couldn't classify the traffic. |
| `duration` | float | Total connection duration in seconds. Absent for connections that were still open when Zeek logged them. |
| `orig_bytes` | int | Payload bytes sent by the originator (does not include IP/TCP headers). Absent for UDP or if Zeek couldn't determine the value. |
| `resp_bytes` | int | Payload bytes sent by the responder. Absent for UDP or if unknown. |
| `conn_state` | string | Summary of the connection's final state (see conn_state values below). |
| `local_orig` | bool | `true` if the originator IP is in a locally-defined network. |
| `local_resp` | bool | `true` if the responder IP is in a locally-defined network. |
| `missed_bytes` | int | Bytes that Zeek missed due to packet loss or capture gaps. `0` means no gaps. |
| `history` | string | Single-character sequence encoding the connection's packet history (e.g., `ShADadFf` for a normal TCP session). See history codes below. |
| `orig_pkts` | int | Total packets sent by the originator. |
| `orig_ip_bytes` | int | Total IP-layer bytes sent by the originator (includes headers). |
| `resp_pkts` | int | Total packets sent by the responder. |
| `resp_ip_bytes` | int | Total IP-layer bytes sent by the responder (includes headers). |
| `orig_l2_addr` | string | Source MAC address (e.g., `e8:4c:4a:db:9c:e8`). **Key field for device joins.** |
| `resp_l2_addr` | string | Destination MAC address. |

### conn_state values

| Value | Meaning |
|-------|---------|
| `S0` | SYN sent, no response — likely a blocked or dropped connection |
| `S1` | TCP connection established, never cleanly closed |
| `SF` | Normal TCP session: SYN, SYN-ACK, data, FIN — clean close by both sides |
| `REJ` | SYN was rejected with RST |
| `S2` | Connection established, originator sent FIN but responder didn't respond |
| `S3` | Connection established, responder sent FIN but originator didn't respond |
| `RSTO` | Connection reset by originator |
| `RSTR` | Connection reset by responder |
| `RSTOS0` | Originator sent SYN then reset before getting a SYN-ACK |
| `RSTRH` | Responder sent SYN-ACK then reset without seeing a SYN |
| `SH` | Originator sent SYN and FIN without SYN-ACK — half-open scan |
| `SHR` | Responder sent SYN-ACK and FIN — unusual |
| `OTH` | No SYN seen (mid-stream capture) |

### history codes

The `history` field encodes each side's packet events as a string. Uppercase
letters = originator, lowercase = responder:

| Letter | Event |
|--------|-------|
| `S`/`s` | SYN packet |
| `H`/`h` | SYN-ACK packet |
| `A`/`a` | Pure ACK (no data) |
| `D`/`d` | Data packet |
| `F`/`f` | FIN packet |
| `R`/`r` | RST packet |
| `C`/`c` | ICMP unreachable |
| `T`/`t` | Retransmitted packet |

A normal HTTP/S connection looks like `ShADadFf` (SYN → SYN-ACK → ACKs → data both ways → FINs).

### Example conn.log event (raw JSON)

```json
{
  "ts": 1741737612.456789,
  "uid": "C5GXBP2kWuMqN1MwMb",
  "id.orig_h": "192.168.1.42",
  "id.orig_p": 54890,
  "id.resp_h": "93.184.216.34",
  "id.resp_p": 443,
  "proto": "tcp",
  "service": "ssl",
  "duration": 2.341,
  "orig_bytes": 1248,
  "resp_bytes": 45120,
  "conn_state": "SF",
  "local_orig": true,
  "local_resp": false,
  "missed_bytes": 0,
  "history": "ShADadFf",
  "orig_pkts": 12,
  "orig_ip_bytes": 1888,
  "resp_pkts": 38,
  "resp_ip_bytes": 47280,
  "orig_l2_addr": "e8:4c:4a:db:9c:e8",
  "resp_l2_addr": "dc:a6:32:01:23:45"
}
```

---

## APL query patterns

### Extract common dns.log fields

```kusto
['firewalla']
| where log_source == "zeek_dns"
| extend parsed     = parse_json(log)
| extend source_mac = tostring(parsed["orig_l2_addr"])
| extend source_ip  = tostring(parsed["id.orig_h"])
| extend domain     = tostring(parsed["query"])
| extend qtype      = tostring(parsed["qtype_name"])
| extend rcode      = tostring(parsed["rcode_name"])
| extend answers    = tostring(parsed["answers"])
```

### Extract common conn.log fields

```kusto
['firewalla']
| where log_source == "zeek_conn"
| extend parsed       = parse_json(log)
| extend source_mac   = tostring(parsed["orig_l2_addr"])
| extend source_ip    = tostring(parsed["id.orig_h"])
| extend dest_ip      = tostring(parsed["id.resp_h"])
| extend dest_port    = toint(parsed["id.resp_p"])
| extend proto        = tostring(parsed["proto"])
| extend service      = tostring(parsed["service"])
| extend orig_bytes   = tolong(parsed["orig_bytes"])
| extend resp_bytes   = tolong(parsed["resp_bytes"])
| extend conn_state   = tostring(parsed["conn_state"])
| extend duration_sec = todouble(parsed["duration"])
```

### Join with device names

Both log types use `orig_l2_addr` as the device identifier for the join:

```kusto
| join kind=leftouter (
    ['firewalla-devices']
    | where record_type == "device_lookup"
    | distinct mac, name
) on $left.source_mac == $right.mac
| extend device = coalesce(name, source_mac)
```

---

## Related

- [dashboards/axiom-queries.md](../dashboards/axiom-queries.md) — full set of APL queries using these fields
- [Zeek DNS log documentation](https://docs.zeek.org/en/master/scripts/base/protocols/dns/main.zeek.html)
- [Zeek conn log documentation](https://docs.zeek.org/en/master/scripts/base/protocols/conn/main.zeek.html)
