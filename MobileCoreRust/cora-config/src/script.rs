//! Pure helpers for Cora's unlock-detection script endpoints and the direct
//! network-info query. Network I/O lives in the FFI crate; everything here is
//! data-in/data-out so it stays testable off-device.
use serde_json::{json, Map as M, Value as J};
use std::net::IpAddr;

pub const MAX_SCRIPT_REQUEST_BODY_BYTES: usize = 32 << 10;
pub const MAX_SCRIPT_RESPONSE_BODY_BYTES: usize = 256 << 10;
pub const MAX_SCRIPT_RESPONSE_HEADER_BYTES: usize = 32 << 10;
pub const MAX_SCRIPT_REQUEST_TIMEOUT_MS: u64 = 15_000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ScriptRequest {
    pub name: String,
    pub group: String,
    pub method: String,
    pub url: String,
    pub headers: Vec<(String, String)>,
    pub body: String,
    pub timeout_ms: u64,
    pub allow_redirect: bool,
}

/// mihomo `ScriptFetch` validation: HTTPS-only, GET/POST/HEAD, bounded body
/// and timeout. Returns the Chinese user-facing errors the app has always
/// surfaced for these cases.
pub fn validate_script_request(v: &J) -> Result<ScriptRequest, String> {
    let body = v["body"].as_str().unwrap_or("").to_string();
    if body.len() > MAX_SCRIPT_REQUEST_BODY_BYTES {
        return Err("脚本请求体超过大小限制".into());
    }
    let url = v["url"].as_str().unwrap_or("").trim().to_string();
    let parsed = url::Url::parse(&url).map_err(|_| "脚本只允许 HTTPS 请求".to_string())?;
    if parsed.scheme() != "https" || parsed.host_str().unwrap_or("").is_empty()
        || parsed.username() != "" || parsed.password().is_some()
    {
        return Err("脚本只允许 HTTPS 请求".into());
    }
    let method = v["method"].as_str().unwrap_or("").trim().to_uppercase();
    let method = if method.is_empty() { "GET".to_string() } else { method };
    match method.as_str() {
        "GET" | "POST" | "HEAD" => {}
        _ => return Err("脚本只允许 GET、POST、HEAD".into()),
    }
    let timeout_ms = match v["timeout"].as_u64() {
        Some(t) if t > 0 && t <= MAX_SCRIPT_REQUEST_TIMEOUT_MS => t,
        _ => MAX_SCRIPT_REQUEST_TIMEOUT_MS,
    };
    let headers = match v["headers"].as_object() {
        Some(map) => map
            .iter()
            .filter(|(k, value)| !k.trim().is_empty() && value.as_str().is_some_and(|s| s.len() <= 4096))
            .map(|(k, value)| (k.clone(), value.as_str().unwrap_or("").to_string()))
            .collect(),
        None => Vec::new(),
    };
    Ok(ScriptRequest {
        name: v["name"].as_str().unwrap_or("").to_string(),
        group: v["group"].as_str().unwrap_or("").to_string(),
        method,
        url,
        headers,
        body,
        timeout_ms,
        allow_redirect: v["allowRedirect"].as_bool().unwrap_or(false),
    })
}

/// mihomo `splitScriptTargetAddress`: `host:port` (bracketed v6 included),
/// anything Go's `net.SplitHostPort` would reject becomes `host` alone.
pub fn split_target_address(address: &str) -> (String, String) {
    let address = address.trim();
    if address.is_empty() {
        return (String::new(), String::new());
    }
    if let Some(rest) = address.strip_prefix('[') {
        if let Some(end) = rest.find(']') {
            let host = &rest[..end];
            let after = &rest[end + 1..];
            if let Some(port) = after.strip_prefix(':') {
                return (host.to_string(), port.to_string());
            }
        }
        return (address.to_string(), String::new());
    }
    if address.matches(':').count() == 1 {
        let mut parts = address.splitn(2, ':');
        return (
            parts.next().unwrap_or("").to_string(),
            parts.next().unwrap_or("").to_string(),
        );
    }
    (address.to_string(), String::new())
}

/// mihomo `usableScriptTargetIP`: no unspecified/loopback, and never the
/// reserved synthetic range (198.18.0.0/15) that fake-IP answers come from.
pub fn usable_target_ip(ip: &IpAddr) -> bool {
    let ip = match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(*ip),
        v4 => *v4,
    };
    if ip.is_unspecified() || ip.is_loopback() {
        return false;
    }
    if let IpAddr::V4(v4) = ip {
        // 198.18.0.0/15 (mask 255.254.0.0)
        if u32::from(v4) & 0xFFFE_0000 == 0xC612_0000 {
            return false;
        }
    }
    true
}

fn json_text(v: &J) -> String {
    match v {
        J::String(s) => s.trim().to_string(),
        J::Number(n) => n.to_string(),
        _ => String::new(),
    }
}

fn first_json_text<'a>(values: impl IntoIterator<Item = &'a J>) -> String {
    for value in values {
        let text = json_text(value);
        if !text.is_empty() {
            return text;
        }
    }
    String::new()
}

fn unmap4(ip: IpAddr) -> Option<std::net::Ipv4Addr> {
    match ip {
        IpAddr::V4(v4) => Some(v4),
        IpAddr::V6(v6) => v6.to_ipv4_mapped(),
    }
}

/// mihomo `parseDirectNetworkInfo`: the ipip.net plain-text format first,
/// then the JSON shape shared by ip.sb and ipwho.is. IPv4 only.
pub fn parse_direct_network_info(data: &[u8]) -> Option<J> {
    let text = String::from_utf8_lossy(data).trim().to_string();
    if text.is_empty() {
        return None;
    }
    if text.contains("当前 IP：") && text.contains("来自于：") {
        if let Some(after) = text.splitn(2, "当前 IP：").nth(1) {
            let mut fields = after.splitn(2, "来自于：");
            let ip = fields.next().unwrap_or("").trim();
            if let Some(v4) = ip.parse::<IpAddr>().ok().and_then(unmap4) {
                let mut out = M::new();
                out.insert("ip".into(), json!(v4.to_string()));
                if let Some(location) = fields.next().map(str::trim).filter(|s| !s.is_empty()) {
                    out.insert("location".into(), json!(location));
                }
                return Some(J::Object(out));
            }
        }
    }
    let object: J = serde_json::from_slice(data).ok()?;
    let ip = json_text(&object["ip"]);
    let v4 = unmap4(ip.parse::<IpAddr>().ok()?)?;
    let mut out = M::new();
    out.insert("ip".into(), json!(v4.to_string()));
    let location = [
        json_text(&object["country"]),
        json_text(&object["region"]),
        json_text(&object["city"]),
    ]
    .into_iter()
    .filter(|s| !s.is_empty())
    .collect::<Vec<_>>()
    .join(" / ");
    if !location.is_empty() {
        out.insert("location".into(), json!(location));
    }
    let asn = json_text(&object["asn"]);
    if !asn.is_empty() {
        out.insert("asn".into(), json!(asn));
    }
    let organization = first_json_text([&object["organization"], &object["asn_organization"], &object["org"]]);
    if !organization.is_empty() {
        out.insert("organization".into(), json!(organization));
    }
    if let Some(connection) = object["connection"].as_object() {
        if !out.contains_key("asn") {
            let asn = connection.get("asn").map(json_text).unwrap_or_default();
            if !asn.is_empty() {
                out.insert("asn".into(), json!(asn));
            }
        }
        if !out.contains_key("organization") {
            let org = ["org", "isp"]
                .iter()
                .filter_map(|k| connection.get(*k))
                .map(json_text)
                .find(|s| !s.is_empty())
                .unwrap_or_default();
            if !org.is_empty() {
                out.insert("organization".into(), json!(org));
            }
        }
    }
    Some(J::Object(out))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_accepts_minimal_https_get() {
        let r = validate_script_request(&json!({"url": "https://example.com/x"})).unwrap();
        assert_eq!(r.method, "GET");
        assert_eq!(r.timeout_ms, MAX_SCRIPT_REQUEST_TIMEOUT_MS);
        assert!(!r.allow_redirect);
    }

    #[test]
    fn validate_rejects_non_https_and_userinfo() {
        for url in ["http://example.com", "https://user@example.com", "https://user:pw@example.com", "ftp://example.com", "notaurl"] {
            let e = validate_script_request(&json!({"url": url})).unwrap_err();
            assert_eq!(e, "脚本只允许 HTTPS 请求", "{url}");
        }
    }

    #[test]
    fn validate_method_whitelist_and_body_cap() {
        assert!(validate_script_request(&json!({"url": "https://a.com", "method": "PUT"})).is_err());
        assert_eq!(
            validate_script_request(&json!({"url": "https://a.com", "method": "post"})).unwrap().method,
            "POST"
        );
        assert!(validate_script_request(&json!({
            "url": "https://a.com",
            "body": "x".repeat(MAX_SCRIPT_REQUEST_BODY_BYTES + 1)
        }))
        .is_err());
        assert!(validate_script_request(&json!({
            "url": "https://a.com",
            "body": "x".repeat(MAX_SCRIPT_REQUEST_BODY_BYTES)
        }))
        .is_ok());
    }

    #[test]
    fn validate_timeout_and_header_rules() {
        let r = validate_script_request(&json!({"url": "https://a.com", "timeout": 500})).unwrap();
        assert_eq!(r.timeout_ms, 500);
        for bad in [0, MAX_SCRIPT_REQUEST_TIMEOUT_MS + 1] {
            let r = validate_script_request(&json!({"url": "https://a.com", "timeout": bad})).unwrap();
            assert_eq!(r.timeout_ms, MAX_SCRIPT_REQUEST_TIMEOUT_MS);
        }
        let r = validate_script_request(&json!({
            "url": "https://a.com",
            "headers": {"Good": "v", "  ": "dropped", "Long": "x".repeat(4097)}
        }))
        .unwrap();
        assert_eq!(r.headers, vec![("Good".to_string(), "v".to_string())]);
    }

    #[test]
    fn split_address_matches_go() {
        assert_eq!(split_target_address("example.com:8443"), ("example.com".into(), "8443".into()));
        assert_eq!(split_target_address("example.com"), ("example.com".into(), "".into()));
        assert_eq!(split_target_address("[2001:db8::1]:443"), ("2001:db8::1".into(), "443".into()));
        assert_eq!(split_target_address("2001:db8::1"), ("2001:db8::1".into(), "".into()));
        assert_eq!(split_target_address(""), ("".into(), "".into()));
        assert_eq!(split_target_address("1.2.3.4:0"), ("1.2.3.4".into(), "0".into()));
    }

    #[test]
    fn usable_ip_rejects_synthetic_and_local() {
        assert!(!usable_target_ip(&"198.18.0.1".parse().unwrap()));
        assert!(!usable_target_ip(&"198.19.255.255".parse().unwrap()));
        assert!(usable_target_ip(&"198.20.0.1".parse().unwrap()));
        assert!(!usable_target_ip(&"127.0.0.1".parse().unwrap()));
        assert!(!usable_target_ip(&"0.0.0.0".parse().unwrap()));
        assert!(!usable_target_ip(&"::1".parse().unwrap()));
        assert!(usable_target_ip(&"203.0.113.7".parse().unwrap()));
        assert!(!usable_target_ip(&"::ffff:198.18.0.1".parse().unwrap()));
        assert!(usable_target_ip(&"2606:4700:4700::1111".parse().unwrap()));
    }

    #[test]
    fn parses_ipip_text_format() {
        let r = parse_direct_network_info("当前 IP：203.0.113.7  来自于：中国 上海 电信".as_bytes()).unwrap();
        assert_eq!(r["ip"], "203.0.113.7");
        assert_eq!(r["location"], "中国 上海 电信");
        assert!(parse_direct_network_info("当前 IP：notanip  来自于：x".as_bytes()).is_none());
        assert!(parse_direct_network_info("当前 IP：2001:db8::1  来自于：x".as_bytes()).is_none());
    }

    #[test]
    fn parses_json_formats() {
        let r = parse_direct_network_info(
            "{\"ip\":\"203.0.113.7\",\"country\":\"中国\",\"region\":\"上海\",\"city\":\"\",\"asn\":\"AS4134\",\"organization\":\"电信\"}".as_bytes(),
        )
        .unwrap();
        assert_eq!(r["ip"], "203.0.113.7");
        assert_eq!(r["location"], "中国 / 上海");
        assert_eq!(r["asn"], "AS4134");
        assert_eq!(r["organization"], "电信");

        let r = parse_direct_network_info(
            br#"{"ip":20301137,"connection":{"asn":"AS1","isp":"isp-name"},"org":"fallback-org"}"#,
        );
        assert!(r.is_none(), "non-IPv4 text must be rejected");

        let r = parse_direct_network_info(
            br#"{"ip":"203.0.113.7","connection":{"asn":"AS1","isp":"isp-name"}}"#,
        )
        .unwrap();
        assert_eq!(r["asn"], "AS1");
        assert_eq!(r["organization"], "isp-name");

        let r = parse_direct_network_info(
            br#"{"ip":"203.0.113.7","asn_organization":"aso","org":"org","organization":"organization"}"#,
        )
        .unwrap();
        assert_eq!(r["organization"], "organization");

        assert!(parse_direct_network_info(br#"{"ip":"::1"}"#).is_none());
        assert!(parse_direct_network_info(b"").is_none());
    }
}
