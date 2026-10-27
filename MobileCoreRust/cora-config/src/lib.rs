//! Pure, network-free configuration inspection. All transformations return copies.
use serde_json::{json, Value as J};
use serde_yaml::{Mapping, Value as Y};
use std::collections::HashSet;

type Result<T> = std::result::Result<T, String>;
fn key(s: &str) -> Y {
    Y::String(s.into())
}
fn str_at<'a>(v: &'a Y, k: &str) -> &'a str {
    v.get(k).and_then(Y::as_str).unwrap_or("")
}
fn flag(v: &J, k: &str, default: bool) -> bool {
    v.get(k).and_then(J::as_bool).unwrap_or(default)
}
pub fn parse(source: &str) -> Result<Y> {
    let mut v: Y = serde_yaml::from_str(source).map_err(|e| e.to_string())?;
    // Match the pinned engine's YAML merge-key semantics before inspection.
    // Expanding only this in-memory value leaves comments/anchors in the source intact.
    v.apply_merge().map_err(|e| e.to_string())?;
    if !v.is_mapping() {
        return Err("$: 配置必须是 YAML mapping".into());
    }
    Ok(v)
}
pub fn yaml(v: &Y) -> Result<String> {
    serde_yaml::to_string(v).map_err(|e| e.to_string())
}
fn set(m: &mut Mapping, k: &str, v: impl Into<Y>) {
    m.insert(key(k), v.into());
}
fn unsupported(path: &str) -> String {
    format!("{path}: 当前 meow-rs iOS 内核无法等价执行，请移除该字段或改用支持的配置")
}

pub fn manifest(source: &str) -> Result<J> {
    let root = parse(source)?;
    let mut proxy = Vec::new();
    let mut rules = Vec::new();
    for (section, out) in [
        ("proxy-providers", &mut proxy),
        ("rule-providers", &mut rules),
    ] {
        if let Some(map) = root.get(section).and_then(Y::as_mapping) {
            for (name, def) in map {
                let name = name
                    .as_str()
                    .ok_or_else(|| format!("{section}: 名称必须是字符串"))?;
                let mut item =
                    json!({"name":name,"type":str_at(def,"type"),"url":str_at(def,"url")});
                if section == "proxy-providers" {
                    let mut headers = serde_json::Map::new();
                    if let Some(h) = def.get("header").and_then(Y::as_mapping) {
                        for (k, v) in h {
                            let values = if let Some(s) = v.as_str() {
                                json!([s])
                            } else {
                                serde_json::to_value(v).map_err(|e| e.to_string())?
                            };
                            headers.insert(k.as_str().unwrap_or("").into(), values);
                        }
                    }
                    item["header"] = J::Object(headers);
                } else {
                    item["behavior"] = json!(str_at(def, "behavior"));
                    item["format"] = json!(str_at(def, "format"));
                }
                out.push(item);
            }
            out.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
        }
    }
    let remote_proxy: Vec<_> = proxy
        .iter()
        .filter(|v| v["type"] == "http")
        .cloned()
        .collect();
    let remote_rules: Vec<_> = rules
        .iter()
        .filter(|v| v["type"] == "http")
        .cloned()
        .collect();
    let groups = root
        .get("proxy-groups")
        .cloned()
        .unwrap_or(Y::Sequence(Vec::new()));
    Ok(
        json!({"providers":remote_proxy,"proxyProviders":remote_proxy,"ruleProviders":remote_rules,
        "requiredProxyProviders":proxy,"requiredRuleProviders":rules,"groupSources":groups}),
    )
}

/// A full Mihomo configuration is also a valid provider response: only proxies are used.
pub fn provider_nodes(payload: &str) -> Result<Vec<Y>> {
    let v = parse(payload)?;
    let nodes = v
        .get("proxies")
        .and_then(Y::as_sequence)
        .ok_or("$.proxies: 节点来源必须包含 proxies 数组")?;
    let mut seen = HashSet::new();
    for (i, n) in nodes.iter().enumerate() {
        let name = str_at(n, "name");
        if name.is_empty() || str_at(n, "type").is_empty() {
            return Err(format!("$.proxies[{i}]: 缺少 name 或 type"));
        }
        if !seen.insert(name) {
            return Err(format!("$.proxies[{i}].name: 重复节点 {name}"));
        }
    }
    Ok(nodes.clone())
}

pub fn mtu(source: &str) -> Result<Option<u16>> {
    let doc = parse(source)?;
    match doc.get("tun").and_then(|t| t.get("mtu")) {
        None | Some(Y::Null) => Ok(None),
        Some(v) if v.as_i64() == Some(0) => Ok(None),
        Some(v) => v
            .as_u64()
            .filter(|v| *v >= 1280 && *v <= 65535)
            .map(|v| Some(v as u16))
            .ok_or("$.tun.mtu: 必须是 1280–65535 的整数".into()),
    }
}

/// Validate paths lexically on every host, including Windows paths in imported YAML.
pub fn contained_path(path: &str) -> bool {
    !path.starts_with('/')
        && !path.starts_with('\\')
        && !path.contains(':')
        && !path.replace('\\', "/").split('/').any(|s| s == "..")
}

pub fn resolve_geo(source: &str, settings: &J) -> Result<J> {
    // No selected profile is Cora's explicit DIRECT mode, not a malformed
    // subscription. It must not trigger unnecessary database downloads.
    let doc = parse(if source.trim().is_empty() {
        "rules: []"
    } else {
        source
    })?;
    // Walk values, including inline rule payloads, DNS policy keys and subrules.
    // Comments and proxy names must not create false database requirements.
    fn references(value: &Y, needle: &str) -> bool {
        match value {
            Y::String(s) => s.to_uppercase().contains(needle),
            Y::Sequence(s) => s.iter().any(|v| references(v, needle)),
            Y::Mapping(m) => m
                .iter()
                .any(|(k, v)| references(k, needle) || references(v, needle)),
            _ => false,
        }
    }
    let sections = ["rules", "sub-rules", "rule-providers", "dns"];
    let has = |needle| {
        sections
            .iter()
            .any(|s| doc.get(*s).is_some_and(|v| references(v, needle)))
    };
    let enabled = flag(settings, "geoEnabled", true);
    let fallback=[("geoip","geoIPDatURL","https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat"),
        ("mmdb","geoMMDBURL","https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb"),
        ("geosite","geoSiteURL","https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat"),
        ("asn","asnURL","https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/GeoLite2-ASN.mmdb")];
    // Remote classical rule providers may contain GEO rules not yet cached.
    let classical = doc
        .get("rule-providers")
        .and_then(Y::as_mapping)
        .is_some_and(|m| {
            m.values()
                .any(|v| str_at(v, "behavior") == "classical" && str_at(v, "type") != "inline")
        });
    let mut out = json!({"geoRequired":enabled && (has("GEOIP,") || has("GEOSITE:") || has("GEOSITE,") || classical),"asnRequired":enabled && (has("IP-ASN,") || classical)});
    for (name, setting, default) in fallback {
        let url = doc
            .get("geodata")
            .and_then(|d| d.get("url"))
            .and_then(|d| d.get(name))
            .and_then(Y::as_str)
            .or_else(|| {
                doc.get("geox-url")
                    .and_then(|d| d.get(name))
                    .and_then(Y::as_str)
            })
            .or_else(|| settings.get(setting).and_then(J::as_str))
            .unwrap_or(default);
        out[name] = json!(url);
    }
    Ok(out)
}

/// Normalize only the runtime copy; original YAML and provider bodies never get written.
pub fn prepare(source: &str, settings: &J, home: &str) -> Result<J> {
    let mut doc = parse(source)?;
    let _ = mtu(source)?;
    let geo = resolve_geo(source, settings)?;
    let root = doc.as_mapping_mut().unwrap();
    let mut notices =
        vec!["iOS 使用 packetFlow + Rust lwIP；运行副本固定 fake-IP，原配置保持不变".to_string()];
    // These are owned by the host rather than by a desktop TUN listener.
    for field in [
        "tun",
        "profile",
        "external-controller",
        "external-controller-tls",
        "external-controller-unix",
        "external-controller-pipe",
        "external-ui",
        "external-ui-url",
        "secret",
        "port",
        "socks-port",
        "tproxy-port",
        "redir-port",
        "listeners",
        "subscriptions",
        "find-process-mode",
        "geo-auto-update",
        "geo-update-interval",
        "geodata-loader",
        "geox-url",
    ] {
        root.remove(key(field));
    }
    // Neither switch has an equivalent implementation in this pinned engine.
    // In particular, unified-delay is not a request to rewrite group test URLs.
    for field in ["geodata-mode", "unified-delay"] {
        if let Some(value) = root.remove(key(field)) {
            match value.as_bool() {
                Some(false) => (),
                Some(true) => return Err(unsupported(&format!("$.{field}"))),
                None => return Err(format!("$.{field}: 必须是布尔值")),
            }
        }
    }
    set(root, "strict", true);
    set(root, "ipv6", flag(settings, "ipv6", false));
    set(
        root,
        "log-level",
        settings["logLevel"].as_str().unwrap_or("info"),
    );
    // Needed for Cora's bounded recently-closed history. Engine retains at most 256.
    set(root, "connection-notes", true);
    if !root.contains_key(key("mode")) {
        set(root, "mode", "rule");
    }
    if settings["blockDirectSTUN"] == true {
        notices.push("旧设置 blockDirectSTUN 已保留，但 meow-rs 暂不支持该 Cora 功能".into());
    }
    if settings["ignoreGeoNegation"] == true {
        notices
            .push("旧 ignoreGeoNegation 偏好已保留，当前内核按配置本身的 GEO 取反语义执行".into());
    }
    if settings["unifiedDelay"] == true {
        notices.push("旧 unifiedDelay 偏好已保留，当前内核不可用；保留各策略组原测速 URL".into());
    }
    let overrides = &settings["overrides"];
    if flag(settings, "applyOverrides", false) && overrides["tun"]["overwrite"] == true {
        notices.push("旧 TUN 覆写已保留；iOS packetFlow 的 DNS 接管、路由和 ICMP 由内核固定管理，无法应用这些旧选项".into());
    }
    if flag(settings, "applyOverrides", false) && overrides["dns"]["overwrite"] == true {
        let o = &overrides["dns"];
        for field in ["respectRules", "preferH3"] {
            if o[field] == true {
                notices.push(format!("旧 DNS 设置 {field} 已保留，当前内核不可用"));
            }
        }
        if o["enhancedMode"].as_str().unwrap_or("fake-ip") != "fake-ip" {
            notices.push("旧 DNS 模式已保留；iOS Rust 数据路径固定使用 fake-IP".into());
        }
        let mut dns = Mapping::new();
        for (src, dst) in [
            ("nameservers", "nameserver"),
            ("defaultNameservers", "default-nameserver"),
            ("proxyNameservers", "proxy-server-nameserver"),
            ("fallbackNameservers", "fallback"),
            ("fakeIPFilter", "fake-ip-filter"),
            ("fakeIPFilterMode", "fake-ip-filter-mode"),
            ("useHosts", "use-hosts"),
            ("useSystemHosts", "use-system-hosts"),
        ] {
            if !o[src].is_null() {
                dns.insert(
                    key(dst),
                    serde_yaml::to_value(&o[src]).map_err(|e| e.to_string())?,
                );
            }
        }
        if o["directNameservers"]
            .as_array()
            .is_some_and(|a| !a.is_empty())
        {
            notices.push(
                "旧 direct-nameserver 设置已保留，meow-rs 无等价接口；使用常规 DNS 配置".into(),
            );
        }
        if let Some(value) = o["fallbackGeoIP"].as_bool() {
            dns.insert(
                key("fallback-filter"),
                Y::Mapping(Mapping::from_iter([(key("geoip"), Y::Bool(value))])),
            );
        }
        root.insert(key("dns"), Y::Mapping(dns));
        if o["useHosts"] == true {
            root.insert(
                key("hosts"),
                serde_yaml::to_value(&o["hosts"]).map_err(|e| e.to_string())?,
            );
        }
    }
    if flag(settings, "applyOverrides", false) && overrides["sniffer"]["overwrite"] == true {
        let o = &overrides["sniffer"];
        let mut sniff = Mapping::new();
        for (src, dst) in [
            ("enable", "enable"),
            ("parsePureIP", "parse-pure-ip"),
            ("overrideDestination", "override-destination"),
            ("forceDomains", "force-domain"),
            ("skipDomains", "skip-domain"),
        ] {
            if !o[src].is_null() {
                sniff.insert(
                    key(dst),
                    serde_yaml::to_value(&o[src]).map_err(|e| e.to_string())?,
                );
            }
        }
        let mut protocols = Mapping::new();
        for (src, dst, ports) in [
            ("http", "HTTP", vec![80, 8080]),
            ("tls", "TLS", vec![443, 8443]),
        ] {
            if o[src] == true {
                protocols.insert(
                    key(dst),
                    serde_yaml::to_value(serde_json::json!({"ports":ports}))
                        .map_err(|e| e.to_string())?,
                );
            }
        }
        sniff.insert(key("sniff"), Y::Mapping(protocols));
        if o["quic"] == true || o["forceDNSMapping"] == true {
            notices
                .push("旧 QUIC 嗅探与 force-dns-mapping 设置已保留，当前内核不提供等价行为".into());
        }
        root.insert(key("sniffer"), Y::Mapping(sniff));
    }
    if let Some(Y::Mapping(dns)) = root.get_mut(key("dns")) {
        if yaml(&Y::Mapping(dns.clone()))?.contains("dhcp://") {
            return Err(unsupported("$.dns: dhcp resolver"));
        }
        if dns
            .get(key("nameserver"))
            .and_then(Y::as_sequence)
            .is_some_and(|v| v.is_empty())
        {
            return Err("$.dns.nameserver: 不能是空数组".into());
        }
        for field in [
            "respect-rules",
            "prefer-h3",
            "direct-nameserver",
            "direct-nameserver-follow-policy",
        ] {
            if let Some(v) = dns.get(key(field)) {
                if v != &Y::Bool(false) && !v.is_null() {
                    return Err(unsupported(&format!("$.dns.{field}")));
                }
            }
            dns.remove(key(field));
        }
        // DNS v6 behavior is enforced by the packet layer, not RawDns.
        dns.remove(key("ipv6"));
        if dns.contains_key(key("cache-max-size")) {
            return Err(unsupported("$.dns.cache-max-size"));
        }
        replace_system_dns(dns, settings)?;
    }
    if !flag(settings, "geoEnabled", true) {
        let needed = resolve_geo(source, &serde_json::json!({"geoEnabled":true}))?;
        if needed["geoRequired"] == true || needed["asnRequired"] == true {
            return Err(
                "$.rules/dns/rule-providers: 配置依赖 GEO/ASN，请启用数据库；不能静默移除规则"
                    .into(),
            );
        }
    } else {
        let geo_home = std::path::Path::new(home);
        let mut g = Mapping::new();
        set(&mut g, "auto-update", false);
        for (k, f) in [
            ("mmdb-path", "geoip.metadb"),
            ("asn-path", "ASN.mmdb"),
            ("geosite-path", "GeoSite.dat"),
        ] {
            set(&mut g, k, geo_home.join(f).to_string_lossy().as_ref());
        }
        let mut urls = Mapping::new();
        for k in ["mmdb", "asn", "geosite"] {
            set(&mut urls, k, geo[k].as_str().unwrap_or(""));
        }
        g.insert(key("url"), Y::Mapping(urls));
        root.insert(key("geodata"), Y::Mapping(g));
    }
    // An unsafe source path must not be flattened to a basename: two providers
    // could alias. Give HTTP caches deterministic independent private paths.
    let mut paths = HashSet::new();
    for section in ["proxy-providers", "rule-providers"] {
        if let Some(Y::Mapping(providers)) = root.get_mut(key(section)) {
            for (name, def) in providers {
                let name = name.as_str().ok_or("provider name must be string")?;
                let provider_type = str_at(def, "type").to_string();
                let old = str_at(def, "path").to_string();
                if provider_type == "file" && !contained_path(&old) {
                    return Err(format!(
                        "$.{section}.{name}.path: 本地路径必须位于 App Group 内"
                    ));
                }
                if let Some(m) = def.as_mapping_mut() {
                    if section == "proxy-providers" {
                        if m.contains_key(key("override-expr")) {
                            return Err(unsupported(&format!("$.{section}.{name}.override-expr")));
                        }
                        if let Some(Y::Mapping(o)) = m.get(key("override")) {
                            for k in o.keys() {
                                if k.as_str() != Some("dialer-proxy") {
                                    return Err(unsupported(&format!(
                                        "$.{section}.{name}.override.{}",
                                        k.as_str().unwrap_or("?")
                                    )));
                                }
                            }
                        }
                    }
                    if provider_type == "http" && (!contained_path(&old) || old.is_empty()) {
                        set(
                            m,
                            "path",
                            format!("./meow-cache/{section}-{}.yaml", hex_name(name)),
                        );
                    }
                    let path = m.get(key("path")).and_then(Y::as_str).unwrap_or("");
                    if !path.is_empty()
                        && !paths
                            .insert(path.replace('\\', "/").trim_start_matches("./").to_string())
                    {
                        return Err(format!("$.{section}.{name}.path: Provider 路径发生冲突"));
                    }
                    if provider_type == "http" {
                        match settings["remoteResourceUpdatePolicy"]
                            .as_str()
                            .unwrap_or("inherit")
                        {
                            "disabled" => set(m, "interval", 0i64),
                            "fixed" => set(
                                m,
                                "interval",
                                (settings["remoteResourceUpdateInterval"]
                                    .as_u64()
                                    .unwrap_or(24)
                                    * 3600) as i64,
                            ),
                            _ => (),
                        }
                    }
                }
            }
        }
    }
    Ok(json!({"yaml":yaml(&doc)?,"notices":notices,"mtu":mtu(source)?}))
}

fn replace_system_dns(map: &mut Mapping, settings: &J) -> Result<()> {
    for v in map.values_mut() {
        match v {
            Y::Sequence(seq) => {
                if seq.iter().any(|v| v.as_str() == Some("system")) {
                    let servers = settings["systemDNS"]
                        .as_array()
                        .filter(|a| !a.is_empty())
                        .ok_or("$.dns: system DNS 尚未从物理网络获取")?;
                    let mut output = Vec::new();
                    for v in seq.iter() {
                        if v.as_str() == Some("system") {
                            for s in servers {
                                if let Some(s) = s.as_str() {
                                    output.push(key(s));
                                }
                            }
                        } else {
                            output.push(v.clone());
                        }
                    }
                    *seq = output;
                }
            }
            Y::Mapping(m) => replace_system_dns(m, settings)?,
            Y::String(s) if s == "system" => {
                let servers = settings["systemDNS"]
                    .as_array()
                    .filter(|a| !a.is_empty())
                    .ok_or("$.dns: system DNS 不可用")?;
                *v = serde_yaml::to_value(servers).map_err(|e| e.to_string())?;
            }
            _ => (),
        }
    }
    Ok(())
}
pub fn hex_name(name: &str) -> String {
    name.as_bytes().iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn no_selected_profile_needs_no_geo_download() {
        let resolved = resolve_geo("", &json!({"geoEnabled":true})).unwrap();
        assert_eq!(resolved["geoRequired"], false);
        assert_eq!(resolved["asnRequired"], false);
    }
    #[test]
    fn complete_config_provider_extracts_only_nodes() {
        assert_eq!(
            provider_nodes(
                "dns: {enable: true}\nproxies: [{name: A, type: ss}]\nrules: [MATCH,DIRECT]"
            )
            .unwrap()
            .len(),
            1
        );
    }
    #[test]
    fn duplicate_nodes_fail() {
        assert!(provider_nodes("proxies: [{name: A, type: ss}, {name: A, type: vless}]").is_err());
    }
    #[test]
    fn yaml_merge_keys_are_expanded_only_in_memory() {
        let source = "# keep anchors\nproxies:\n  - &base {name: A, type: ss, server: example.org, port: 443}\n  - {<<: *base, name: B}\n";
        let original = source.to_string();
        let nodes = provider_nodes(source).unwrap();
        assert_eq!(nodes[1]["name"].as_str(), Some("B"));
        assert_eq!(nodes[1]["type"].as_str(), Some("ss"));
        assert!(nodes[1].get("<<").is_none());
        let prepared = prepare(source, &json!({}), "/home").unwrap();
        let doc = parse(prepared["yaml"].as_str().unwrap()).unwrap();
        assert_eq!(doc["proxies"][1]["server"].as_str(), Some("example.org"));
        assert_eq!(source, original);
    }
    #[test]
    fn headers_keep_lists() {
        let m=manifest("proxy-providers: {p: {type: http, url: 'https://example.com/p', header: {UA: [one,two]}}}").unwrap();
        assert_eq!(m["providers"][0]["header"]["UA"], json!(["one", "two"]));
    }
    #[test]
    fn source_is_immutable() {
        let s = "# source\nrules: [MATCH,DIRECT]\n";
        let before = s.as_bytes().to_vec();
        let _ = prepare(s, &json!({"geoEnabled":false}), "/home").unwrap();
        assert_eq!(s.as_bytes(), before);
    }
    #[test]
    fn mtu_type_and_range() {
        assert!(mtu("tun: {mtu: nope}").is_err());
        assert!(mtu("tun: {mtu: 100}").is_err());
        assert_eq!(mtu("tun: {mtu: 1400}").unwrap(), Some(1400));
    }
    #[test]
    fn paths_reject_windows_and_parent() {
        for p in ["C:\\a", "/a", "../a", "./x/../a", "\\\\host\\a"] {
            assert!(!contained_path(p));
        }
        assert!(contained_path("./rules/cn.yaml"));
    }
    #[test]
    fn unsafe_http_paths_are_unique() {
        let r = prepare(
            "proxy-providers: {a: {type: http, path: /a/x}, b: {type: http, path: /b/x}}",
            &json!({"geoEnabled":false}),
            "/home",
        )
        .unwrap();
        let d = parse(r["yaml"].as_str().unwrap()).unwrap();
        assert_ne!(
            d["proxy-providers"]["a"]["path"],
            d["proxy-providers"]["b"]["path"]
        );
    }
    #[test]
    fn unsafe_file_is_error() {
        assert!(prepare(
            "rule-providers: {p: {type: file, path: ../a}}",
            &json!({}),
            "/home"
        )
        .is_err());
    }
    #[test]
    fn override_expr_not_silently_ignored() {
        assert!(prepare(
            "proxy-providers: {p: {type: http, override-expr: foo}}",
            &json!({}),
            "/home"
        )
        .unwrap_err()
        .contains("override-expr"));
    }
    #[test]
    fn original_rules_order() {
        let r = prepare(
            "rules: [DOMAIN,a,DIRECT, MATCH,DIRECT]",
            &json!({"geoEnabled":false}),
            "/home",
        )
        .unwrap();
        assert!(r["yaml"].as_str().unwrap().contains("DOMAIN"));
    }
    #[test]
    fn system_dns_never_becomes_fallback_zero() {
        assert!(prepare("dns: {nameserver: [system]}", &json!({}), "/home").is_err());
        let d = prepare(
            "dns: {nameserver: [system]}",
            &json!({"systemDNS":["8.8.8.8"]}),
            "/home",
        )
        .unwrap();
        assert!(d["yaml"].as_str().unwrap().contains("8.8.8.8"));
    }
    #[test]
    fn unsupported_dns_error_has_path() {
        assert!(prepare("dns: {respect-rules: true}", &json!({}), "/home")
            .unwrap_err()
            .contains("$.dns.respect-rules"));
    }
    #[test]
    fn provider_path_collision_is_error() {
        assert!(prepare(
            "proxy-providers: {a: {type: http, path: ./same}, b: {type: http, path: same}}",
            &json!({}),
            "/home"
        )
        .is_err());
    }
    #[test]
    fn rule_provider_manifest_preserves_format() {
        let v = manifest(
            "rule-providers: {p: {type: http, url: 'https://a', behavior: classical, format: mrs}}",
        )
        .unwrap();
        assert_eq!(v["ruleProviders"][0]["format"], "mrs");
    }
    #[test]
    fn legacy_default_settings_do_not_block_new_core() {
        let settings = json!({"applyOverrides":true,"blockDirectSTUN":true,"overrides":{
            "tun":{"overwrite":true,"dnsHijack":["any:53"],"icmpForwarding":true},
            "dns":{"overwrite":true,"directNameservers":["system"],"nameservers":["https://1.1.1.1/dns-query"],"enhancedMode":"fake-ip"},
            "sniffer":{"overwrite":true,"enable":true,"http":true,"tls":true,"quic":true,"forceDNSMapping":true}}});
        let before = settings.clone();
        let output = prepare("rules: ['MATCH,DIRECT']", &settings, "/home").unwrap();
        assert_eq!(before, settings);
        assert!(output["notices"].as_array().unwrap().len() >= 4);
        let doc = parse(output["yaml"].as_str().unwrap()).unwrap();
        assert_eq!(doc["sniffer"]["enable"], Y::Bool(true));
        assert!(doc["dns"].get("direct-nameserver").is_none());
    }
    #[test]
    fn disabled_geo_never_removes_routing_rules() {
        let source = "rules: ['GEOIP,CN,DIRECT', 'MATCH,DIRECT']";
        assert!(prepare(source, &json!({"geoEnabled":false}), "/home")
            .unwrap_err()
            .contains("不能静默"));
        assert!(source.contains("GEOIP,CN,DIRECT"));
    }
    #[test]
    fn geo_comments_are_not_rules() {
        assert_eq!(
            resolve_geo("# GEOIP,CN,DIRECT\nrules: ['MATCH,DIRECT']", &json!({})).unwrap()
                ["geoRequired"],
            false
        );
    }
    #[test]
    fn classical_remote_provider_requires_geo_and_asn() {
        let g = resolve_geo(
            "rule-providers: {p: {type: http, behavior: classical, url: 'https://example.org'}}",
            &json!({}),
        )
        .unwrap();
        assert_eq!(g["geoRequired"], true);
        assert_eq!(g["asnRequired"], true);
    }
    #[test]
    fn metadata_separates_remote_from_required_providers() {
        let m=manifest("proxy-providers: {i: {type: inline, payload: []}, f: {type: file, path: ./nodes}, h: {type: http, url: 'https://a'}}").unwrap();
        assert_eq!(m["providers"].as_array().unwrap().len(), 1);
        assert_eq!(m["requiredProxyProviders"].as_array().unwrap().len(), 3);
    }
    #[test]
    fn unsupported_source_cache_and_dhcp_fail_with_path() {
        for (s, path) in [
            ("dns: {cache-max-size: 1024}", "$.dns.cache-max-size"),
            ("dns: {nameserver: ['dhcp://en0']}", "$.dns"),
            ("dns: {nameserver: []}", "$.dns.nameserver"),
        ] {
            assert!(prepare(s, &json!({}), "/home").unwrap_err().contains(path));
        }
    }
    #[test]
    fn unsupported_source_switches_never_change_semantics() {
        for field in ["geodata-mode", "unified-delay"] {
            for value in ["true", "invalid"] {
                let source = format!("{field}: {value}\nrules: ['MATCH,DIRECT']");
                let before = source.clone();
                assert!(prepare(&source, &json!({}), "/home")
                    .unwrap_err()
                    .contains(&format!("$.{field}")));
                assert_eq!(source, before);
            }
            let output = prepare(&format!("{field}: false"), &json!({}), "/home").unwrap();
            assert!(parse(output["yaml"].as_str().unwrap())
                .unwrap()
                .get(field)
                .is_none());
        }
    }
    #[test]
    fn legacy_unified_delay_keeps_group_urls_and_saved_preference() {
        let source = "proxy-groups: [{name: Auto, type: url-test, proxies: [DIRECT], url: 'https://example.org/check'}]";
        let settings =
            json!({"unifiedDelay":true,"delayTestURL":"https://different.example/check"});
        let output = prepare(source, &settings, "/home").unwrap();
        let doc = parse(output["yaml"].as_str().unwrap()).unwrap();
        assert_eq!(
            doc["proxy-groups"][0]["url"].as_str(),
            Some("https://example.org/check")
        );
        assert_eq!(settings["unifiedDelay"], true);
        assert!(output["notices"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n.as_str().unwrap().contains("unifiedDelay")));
    }
}
