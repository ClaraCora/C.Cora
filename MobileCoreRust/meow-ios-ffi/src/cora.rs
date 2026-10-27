//! Cora-specific, versioned JSON ABI. No engine is started in the main app.
use crate::{engine, get_engine_runtime};
use anyhow::{anyhow, bail, Context, Result};
use parking_lot::Mutex;
use serde_json::{json, Value as J};
use serde_yaml::Value as Y;
use std::{
    collections::{HashSet, VecDeque},
    ffi::{c_char, CString},
    path::{Path, PathBuf},
    sync::{Arc, OnceLock},
    time::Instant,
};

const MAX_REQUEST: usize = 16 * 1024 * 1024;
fn k(s: &str) -> Y {
    Y::String(s.into())
}
fn text<'a>(j: &'a J, key: &str) -> &'a str {
    j[key].as_str().unwrap_or("")
}

/// Versioned JSON request. Returns an owned UTF-8 JSON string; free exactly once
/// with `meow_string_free`. Never call lifecycle methods from a runtime callback.
/// # Safety
/// `input` points to `len` valid bytes for this call only; Rust retains no pointer.
#[no_mangle]
pub unsafe extern "C" fn cora_core_request(input: *const u8, len: usize) -> *mut c_char {
    let response = if input.is_null() || len == 0 || len > MAX_REQUEST {
        json!({"ok":false,"error":"Cora core request exceeds limits"})
    } else {
        let data = std::slice::from_raw_parts(input, len);
        match serde_json::from_slice::<J>(data)
            .map_err(anyhow::Error::from)
            .and_then(dispatch)
        {
            Ok(v) => v,
            Err(e) => json!({"ok":false,"error":format!("{e:#}")}),
        }
    };
    CString::new(response.to_string())
        .expect("JSON never contains literal NUL")
        .into_raw()
}

fn dispatch(j: J) -> Result<J> {
    if j["v"].as_i64().unwrap_or(1) != 1 {
        bail!("Unsupported Cora core ABI version");
    }
    let source = text(&j, "yaml");
    match text(&j, "cmd") {
        "version" => Ok(
            json!({"version":"meow-rs 0.26.1+fa7a7d6","engineCommit":"fa7a7d6dc94e886ae0bc43eeb0227082ae5bf2e6","abi":1}),
        ),
        "manifest" => cora_config::manifest(source).map_err(|e| anyhow!(e)),
        "validateProvider" => {
            cora_config::provider_nodes(text(&j, "payload")).map_err(|e| anyhow!(e))?;
            Ok(json!({"ok":true}))
        }
        "configInfo" => Ok(json!({"mtu":cora_config::mtu(source).map_err(|e|anyhow!(e))?})),
        "resolveGeo" => cora_config::resolve_geo(source, &j["settings"]).map_err(|e| anyhow!(e)),
        "prepare" => prepare(&j),
        "validate" => {
            let prepared = cora_config::prepare(source, &j["settings"], text(&j, "home"))
                .map_err(|e| anyhow!(e))?;
            checked_shape(text(&prepared, "yaml"))?;
            Ok(json!({"ok":true,"notices":prepared["notices"]}))
        }
        "convertSubscription" => {
            Ok(json!({"yaml":crate::subscription::convert(text(&j,"body").as_bytes())?}))
        }
        "offlineSnapshot" => offline(&j),
        "validateGeo" => {
            validate_geo(Path::new(text(&j, "path")), text(&j, "kind"))?;
            Ok(json!({"ok":true}))
        }
        "traffic" | "runtime" | "connections" | "historyActive" | "historyClosed" => runtime(&j),
        "ruleContent" => rule_content(&j),
        "resetSession" => {
            *history().lock() = History::default();
            *started().lock() = Instant::now();
            Ok(json!({"ok":true}))
        }
        _ => bail!("Unsupported Cora core command"),
    }
}

fn checked_shape(source: &str) -> Result<()> {
    let doc = cora_config::parse(source).map_err(|e| anyhow!(e))?;
    let supported = serde_yaml::to_value(meow_config::raw::RawConfig::default())?;
    for key in doc.as_mapping().unwrap().keys() {
        if !supported.as_mapping().unwrap().contains_key(key) {
            bail!(
                "$.{}: meow-rs 不支持此配置字段",
                key.as_str().unwrap_or("?")
            );
        }
    }
    // RawConfig's unknown-field behavior is lenient; compare nested typed fields
    // too, before the upstream loader can warn-and-ignore a routing setting.
    let default_dns: meow_config::raw::RawDns = serde_yaml::from_str("{}")?;
    for (section, fields) in [
        ("dns", serde_yaml::to_value(default_dns)?),
        (
            "sniffer",
            serde_yaml::to_value(meow_config::raw::RawSniffer::default())?,
        ),
    ] {
        if let Some(m) = doc.get(section).and_then(Y::as_mapping) {
            for key in m.keys() {
                if !fields.as_mapping().unwrap().contains_key(key) {
                    bail!(
                        "$.{section}.{}: meow-rs 不支持此字段",
                        key.as_str().unwrap_or("?")
                    );
                }
            }
        }
    }
    if let Some(sniff) = doc
        .get("sniffer")
        .and_then(|v| v.get("sniff"))
        .and_then(Y::as_mapping)
    {
        for protocol in sniff.keys() {
            if !matches!(protocol.as_str(), Some("HTTP" | "TLS")) {
                bail!(
                    "$.sniffer.sniff.{}: 不支持该嗅探协议",
                    protocol.as_str().unwrap_or("?")
                );
            }
        }
    }
    meow_config::parse_raw_yaml(source).context("配置结构校验")?;
    Ok(())
}

fn prepare(j: &J) -> Result<J> {
    let home = Path::new(text(j, "home"));
    if !home.is_absolute() {
        bail!("Core home must be absolute");
    }
    let input = text(j, "yaml");
    let mut result = cora_config::prepare(
        input,
        &j["settings"],
        home.to_str().ok_or_else(|| anyhow!("home encoding"))?,
    )
    .map_err(|e| anyhow!(e))?;
    let prepared = text(&result, "yaml").to_string();
    let mut doc = cora_config::parse(&prepared).map_err(|e| anyhow!(e))?;
    let namespace = text(j, "cacheNamespace");
    if namespace.len() != 64 || !namespace.bytes().all(|b| b.is_ascii_hexdigit()) {
        bail!("cacheNamespace: expected a SHA-256 profile digest");
    }
    materialize_inline(&mut doc, home, namespace)?;
    // Distinct cache namespace: never let an HTTP refresh overwrite a file
    // imported by the user or a cache owned by the former Go core.
    isolate_http_caches(&mut doc, home, namespace)?;
    for section in ["proxy-providers", "rule-providers"] {
        if let Some(providers) = doc.get(section).and_then(Y::as_mapping) {
            for (name, def) in providers {
                if def["type"].as_str() == Some("file") {
                    safe_file(home, def["path"].as_str().unwrap_or("")).with_context(|| {
                        format!("$.{section}.{}.path", name.as_str().unwrap_or("?"))
                    })?;
                }
            }
        }
    }
    let raw = cora_config::yaml(&doc).map_err(|e| anyhow!(e))?;
    checked_shape(&raw)?;
    let input = CString::new(raw)?;
    let mixed = j["mixedPort"].as_i64().unwrap_or(0) as i32;
    let dns = j["dnsPort"].as_i64().unwrap_or(0) as i32;
    // A positive port is always chosen by the host, even when LAN proxy is off.
    if !(1..=65535).contains(&mixed) || !(1..=65535).contains(&dns) {
        bail!("Invalid internal listener ports");
    }
    let n =
        unsafe { crate::meow_patch_config(input.as_ptr(), mixed, 0, dns, std::ptr::null_mut(), 0) };
    if n < 0 {
        bail!("iOS config patch failed");
    }
    let mut out = vec![0i8; n as usize + 1];
    let n2 = unsafe {
        crate::meow_patch_config(
            input.as_ptr(),
            mixed,
            0,
            dns,
            out.as_mut_ptr(),
            out.len() as i32,
        )
    };
    if n2 < 0 || n2 as usize >= out.len() {
        bail!("iOS config patch exceeded output buffer");
    }
    let patched = unsafe { std::ffi::CStr::from_ptr(out.as_ptr()) }.to_str()?;
    let mut patched = cora_config::parse(patched).map_err(|e| anyhow!(e))?;
    patched.as_mapping_mut().unwrap().remove(k("geox-url"));
    let port = std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, 0))?
        .local_addr()?
        .port();
    let secret: String = rand::random::<[u8; 32]>()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    patched
        .as_mapping_mut()
        .unwrap()
        .insert(k("external-controller"), k(&format!("127.0.0.1:{port}")));
    patched
        .as_mapping_mut()
        .unwrap()
        .insert(k("secret"), k(&secret));
    // The upstream app appends public fallback resolvers. Cora must preserve
    // configured resolver choices; only the five iOS transport keys are pinned.
    if let Some(original) = doc.get("dns").and_then(Y::as_mapping) {
        let mut dns = original.clone();
        if let Some(port) = original
            .get(k("listen"))
            .and_then(Y::as_str)
            .and_then(crate::parse_listen_port)
        {
            crate::rewrite_self_referential_nameservers(&mut dns, port, dns_port(j)?);
        }
        for key in [
            "enable",
            "listen",
            "enhanced-mode",
            "store-fake-ip",
            "fake-ip-range",
        ] {
            dns.insert(k(key), patched["dns"][key].clone());
        }
        if !dns.contains_key(k("nameserver")) {
            dns.insert(k("nameserver"), patched["dns"]["nameserver"].clone());
        }
        patched
            .as_mapping_mut()
            .unwrap()
            .insert(k("dns"), Y::Mapping(dns));
    }
    // The upstream app forces its sniffer. Cora honors the user's own block,
    // including the absence of one (the engine's default), without opt-in.
    if let Some(sniffer) = doc.get("sniffer") {
        patched
            .as_mapping_mut()
            .unwrap()
            .insert(k("sniffer"), sniffer.clone());
    } else {
        patched.as_mapping_mut().unwrap().remove(k("sniffer"));
    }
    // The packet bridge's SOCKS handshake is internal and has no user auth.
    // Keep configured credentials, but exempt loopback in the runtime copy;
    // the mixed listener is always pinned to loopback above.
    patched.as_mapping_mut().unwrap().insert(
        k("skip-auth-prefixes"),
        serde_yaml::from_str("['127.0.0.0/8', '::1/128']")?,
    );
    if doc.get("authentication").is_some() {
        let mut notices = result["notices"].as_array().cloned().unwrap_or_default();
        notices.push(json!(
            "运行副本仅为 packetFlow 的本机 SOCKS 连接豁免认证，源配置的 authentication 保持不变"
        ));
        result["notices"] = J::Array(notices);
    }
    checked_shape(&cora_config::yaml(&patched).map_err(|e| anyhow!(e))?)?;
    result["controller"] = json!(patched["external-controller"].as_str().unwrap_or(""));
    result["secret"] = json!(patched["secret"].as_str().unwrap_or(""));
    result["yaml"] = json!(cora_config::yaml(&patched).map_err(|e| anyhow!(e))?);
    crate::file_log::set_level(patched["log-level"].as_str().unwrap_or("info"));
    Ok(result)
}

fn dns_port(j: &J) -> Result<u16> {
    Ok(j["dnsPort"]
        .as_u64()
        .filter(|v| *v > 0 && *v <= 65535)
        .context("dnsPort")? as u16)
}

fn materialize_inline(doc: &mut Y, home: &Path, namespace: &str) -> Result<()> {
    if let Some(providers) = doc.get_mut("proxy-providers").and_then(Y::as_mapping_mut) {
        for (name, def) in providers {
            if def["type"].as_str() != Some("inline") {
                continue;
            }
            let nodes = def
                .get("payload")
                .and_then(Y::as_sequence)
                .context("inline provider payload must be a sequence")?
                .clone();
            let file = format!(
                "./meow-inline/{namespace}/{}.yaml",
                cora_config::hex_name(name.as_str().context("provider name")?)
            );
            let payload = serde_yaml::to_string(&serde_json::json!({"proxies":nodes}))?;
            cora_config::provider_nodes(&payload).map_err(|e| anyhow!(e))?;
            let parent = home.join(format!("meow-inline/{namespace}"));
            std::fs::create_dir_all(&parent)?;
            if !parent.canonicalize()?.starts_with(home.canonicalize()?) {
                bail!("Inline cache escapes home");
            }
            atomic_file(&home.join(&file), payload.as_bytes())?;
            let m = def.as_mapping_mut().context("inline provider mapping")?;
            m.insert(k("type"), k("file"));
            m.insert(k("path"), k(&file));
            m.remove(k("payload"));
        }
    }
    Ok(())
}
fn isolate_http_caches(doc: &mut Y, home: &Path, namespace: &str) -> Result<()> {
    for section in ["proxy-providers", "rule-providers"] {
        if let Some(providers) = doc.get_mut(section).and_then(Y::as_mapping_mut) {
            for (name, def) in providers {
                if def["type"].as_str() != Some("http") {
                    continue;
                }
                let next = format!(
                    "./meow-cache/{namespace}/{section}-{}.yaml",
                    cora_config::hex_name(name.as_str().context("provider name")?)
                );
                std::fs::create_dir_all(home.join(format!("meow-cache/{namespace}")))?;
                // Do not seed from a former core's shared path: a same-named
                // provider in another profile may own that file.
                let parent = home
                    .join(format!("meow-cache/{namespace}"))
                    .canonicalize()?;
                if !parent.starts_with(home.canonicalize()?) {
                    bail!("Provider cache escapes home");
                }
                if home.join(&next).exists() {
                    safe_file(home, &next)?;
                }
                def.as_mapping_mut().unwrap().insert(k("path"), k(&next));
            }
        }
    }
    Ok(())
}
fn safe_file(home: &Path, relative: &str) -> Result<PathBuf> {
    if relative.is_empty() || !cora_config::contained_path(relative) {
        bail!("Provider path escapes home");
    }
    let base = home.canonicalize()?;
    let file = base
        .join(relative)
        .canonicalize()
        .context("Provider file not found")?;
    if !file.starts_with(&base) || !file.is_file() {
        bail!("Provider path escapes home or is not a file");
    }
    Ok(file)
}
fn atomic_file(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let temp = path.with_extension(format!("{}.tmp", rand::random::<u64>()));
    std::fs::write(&temp, bytes)?;
    if let Err(e) = std::fs::rename(&temp, path) {
        let _ = std::fs::remove_file(&temp);
        return Err(e.into());
    }
    Ok(())
}

fn proxy_info(p: &Arc<dyn meow_common::Proxy>) -> J {
    let mut info = json!({"name":p.name(),"type":p.adapter_type().to_string(),"alive":p.alive(),"history":p.delay_history(),"udp":p.support_udp(),"provider-name":""});
    if let Some(members) = p.members() {
        info["all"] = json!(members);
        info["now"] = json!(p.current());
        if let Some(display) = p.group_display() {
            info["hidden"] = json!(display.hidden);
            info["icon"] = json!(display.icon.to_string());
        }
    }
    info
}

/// Offline catalogs use the actual upstream group builder, with cached provider
/// bodies materialized into a disposable directory. No HTTP download is allowed.
fn offline(j: &J) -> Result<J> {
    static OFFLINE: Mutex<()> = Mutex::new(());
    let _guard = OFFLINE.lock();
    let temp = std::env::temp_dir().join(format!("cora-catalog-{}", rand::random::<u64>()));
    std::fs::create_dir_all(&temp)?;
    struct Clean(PathBuf);
    impl Drop for Clean {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _clean = Clean(temp.clone());
    let mut doc = cora_config::parse(text(j, "yaml")).map_err(|e| anyhow!(e))?;
    let root = doc.as_mapping_mut().unwrap();
    for key in [
        "rule-providers",
        "sub-rules",
        "geodata",
        "geox-url",
        "subscriptions",
        "listeners",
        "tun",
        "external-controller",
    ] {
        root.remove(k(key));
    }
    root.insert(k("rules"), serde_yaml::from_str("['MATCH,DIRECT']")?);
    root.insert(k("dns"), serde_yaml::from_str("{enable: false}")?);
    root.insert(k("strict"), Y::Bool(true));
    let mut missing = Vec::new();
    if let Some(m) = root
        .get_mut(k("proxy-providers"))
        .and_then(Y::as_mapping_mut)
    {
        for (name, def) in m {
            let name = name.as_str().context("provider name")?;
            let nodes = if def["type"].as_str() == Some("inline") {
                def["payload"].as_sequence().cloned().unwrap_or_default()
            } else if let Some(body) = j["providers"][name].as_str() {
                cora_config::provider_nodes(body).map_err(|e| anyhow!("{name}: {e}"))?
            } else {
                let home = Path::new(text(j, "home"));
                let cache = format!(
                    "./meow-cache/{}/proxy-providers-{}.yaml",
                    text(j, "cacheNamespace"),
                    cora_config::hex_name(name)
                );
                let path = if def["type"].as_str() == Some("file") {
                    def["path"].as_str().unwrap_or("")
                } else {
                    &cache
                };
                match safe_file(home, path).and_then(|p| Ok(std::fs::read_to_string(p)?)) {
                    Ok(body) => cora_config::provider_nodes(&body).map_err(|e| anyhow!(e))?,
                    Err(_) => {
                        missing.push(name.to_string());
                        Vec::new()
                    }
                }
            };
            let file = format!("{}.yaml", cora_config::hex_name(name));
            atomic_file(
                &temp.join(&file),
                serde_yaml::to_string(&json!({"proxies":nodes}))?.as_bytes(),
            )?;
            let m = def.as_mapping_mut().context("provider mapping")?;
            m.insert(k("type"), k("file"));
            m.insert(k("path"), k(&file));
            m.remove(k("payload"));
            m.remove(k("url"));
            m.insert(k("interval"), Y::Number(0.into()));
            m.remove(k("health-check"));
        }
    }
    let path = temp.join("catalog.yaml");
    std::fs::write(&path, serde_yaml::to_string(&doc)?)?;
    let cfg = get_engine_runtime().block_on(meow_config::load_config(
        path.to_str().context("catalog path")?,
    ))?;
    let mut proxies = serde_json::Map::new();
    let mut types = serde_json::Map::new();
    let mut node_count = 0;
    for (name, p) in &cfg.proxies {
        let mut info = proxy_info(p);
        if let Some(selected) = j["selections"][name.as_str()].as_str() {
            if info["all"]
                .as_array()
                .is_some_and(|a| a.iter().any(|v| v == selected))
            {
                info["now"] = json!(selected);
            }
        }
        if p.members().is_none() {
            types.insert(name.to_string(), json!(p.adapter_type().to_string()));
            if !["DIRECT", "REJECT", "PASS", "COMPATIBLE"].contains(&name.as_str()) {
                node_count += 1;
            }
        }
        proxies.insert(name.to_string(), info);
    }
    let mut catalog = Vec::new();
    for (provider_name, provider) in &cfg.proxy_providers {
        for p in provider.proxies() {
            let mut info = proxy_info(&p);
            info["provider-name"] = json!(provider_name.to_string());
            catalog.push(info);
            // Same-name nodes cannot be flattened to a guessed type.
            types
                .entry(p.name().to_string())
                .or_insert(json!(p.adapter_type().to_string()));
            node_count += 1;
        }
    }
    let order: Vec<_> = doc
        .get("proxy-groups")
        .and_then(Y::as_sequence)
        .into_iter()
        .flatten()
        .filter_map(|g| g["name"].as_str())
        .map(str::to_owned)
        .collect();
    proxies.entry("GLOBAL".to_string()).or_insert(json!({"name":"GLOBAL","type":"Selector","all":order,"now":order.first().cloned().unwrap_or("DIRECT".into())}));
    Ok(
        json!({"mode":doc["mode"].as_str().unwrap_or("rule"),"proxies":proxies,"nodeTypes":types,"providerNodes":catalog,"nodeCount":node_count,"missingProviders":missing}),
    )
}

fn validate_geo(path: &Path, kind: &str) -> Result<()> {
    let size = std::fs::metadata(path)?.len();
    if size == 0 || size > 64 * 1024 * 1024 {
        bail!("GEO database exceeds size limit");
    }
    match kind {
        "mmdb" | "asn" => {
            maxminddb::Reader::open_readfile(path).context("Invalid MMDB")?;
        }
        "geosite" => {
            meow_rules::geosite::GeositeDB::load_from_path(path, None)
                .context("Invalid GeoSite database")?;
        }
        "geoip" => bail!("GeoIP.dat is unavailable in meow-rs; select MMDB mode"),
        _ => bail!("Unknown database kind"),
    }
    Ok(())
}

fn rule_content(j: &J) -> Result<J> {
    let name = text(j, "name");
    if name.is_empty() || name.len() > 256 {
        bail!("Rule Provider 名称无效");
    }
    let max_bytes = j["maxBytes"].as_u64().unwrap_or(1 << 20).clamp(1, 1 << 20) as usize;
    let doc = cora_config::parse(text(j, "yaml")).map_err(|e| anyhow!(e))?;
    let def = doc["rule-providers"][name]
        .as_mapping()
        .context("找不到 Rule Provider")?;
    if def.get(k("format")).and_then(Y::as_str) == Some("mrs") {
        bail!("Rule Provider {name}: MRS 二进制内容暂不支持文本预览");
    }
    if def.get(k("type")).and_then(Y::as_str) == Some("inline") {
        let payload = def
            .get(k("payload"))
            .and_then(Y::as_sequence)
            .context("inline rule payload")?;
        let content = payload
            .iter()
            .map(|v| v.as_str().context("inline rule must be text"))
            .collect::<Result<Vec<_>>>()?
            .join("\n");
        let size = content.len();
        let mut end = size.min(max_bytes);
        while !content.is_char_boundary(end) {
            end -= 1;
        }
        return Ok(json!({"ok":true,"content":&content[..end],"size":size,"truncated":end<size}));
    }
    let path = def
        .get(k("path"))
        .and_then(Y::as_str)
        .context("Rule Provider 没有本地缓存路径")?;
    if !cora_config::contained_path(path) {
        bail!("Rule Provider 路径超出 App Group");
    }
    let file = safe_file(Path::new(text(j, "home")), path)?;
    let metadata = std::fs::metadata(&file)?;
    if metadata.len() > (1 << 20) {
        bail!("Rule Provider 内容超过 1 MB 上限");
    }
    let content =
        String::from_utf8(std::fs::read(&file)?).context("Rule Provider 不是 UTF-8 文本")?;
    let mut end = content.len().min(max_bytes);
    while !content.is_char_boundary(end) {
        end -= 1;
    }
    let updated = metadata
        .modified()?
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs();
    Ok(
        json!({"ok":true,"content":&content[..end],"size":content.len(),"updatedAtUnix":updated,"truncated":content.len()>end}),
    )
}

fn started() -> &'static Mutex<Instant> {
    static S: OnceLock<Mutex<Instant>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(Instant::now()))
}
#[derive(Default)]
struct History {
    sequence: u64,
    seen: HashSet<String>,
    entries: VecDeque<(u64, J)>,
}
fn history() -> &'static Mutex<History> {
    static H: OnceLock<Mutex<History>> = OnceLock::new();
    H.get_or_init(|| Mutex::new(History::default()))
}
fn runtime(j: &J) -> Result<J> {
    let tunnel = engine::tunnel().context("engine not running")?;
    let stats = tunnel.statistics();
    let (up, down) = stats.snapshot();
    let limit = j["limit"].as_u64().unwrap_or(256).min(512) as usize;
    match text(j, "cmd") {
        "runtime" => Ok(
            json!({"engine":"meow-rs","version":"0.26.1+fa7a7d6","residentBytes":crate::rss::resident_bytes(),"activeTCP":crate::meow_active_tcp_conns(),"uploadTotal":up,"downloadTotal":down,"uptime":started().lock().elapsed().as_secs(),"udpConnectionDetails":false}),
        ),
        "traffic" => {
            let (ur, dr, _, _) = stats.traffic_snapshot();
            Ok(
                json!({"up":ur,"down":dr,"uploadTotal":up,"downloadTotal":down,"uptime":started().lock().elapsed().as_secs()}),
            )
        }
        "connections" | "historyActive" => {
            let total = stats.active_connection_count();
            let rows: Vec<_> = stats
                .connections
                .iter()
                .take(limit)
                .map(|r| serde_json::to_value(r.value()))
                .collect::<std::result::Result<_, _>>()?;
            Ok(
                json!({"connections":rows,"uploadTotal":up,"downloadTotal":down,"total":total,"truncated":total>limit,"udpDetailsAvailable":false}),
            )
        }
        "historyClosed" => {
            let recent = stats.recently_closed();
            let mut h = history().lock();
            let ids: HashSet<_> = recent.iter().map(|c| c.info.id.to_string()).collect();
            for c in recent {
                let id = c.info.id.to_string();
                if !h.seen.contains(&id) {
                    h.sequence += 1;
                    let seq = h.sequence;
                    h.entries.push_back((seq, serde_json::to_value(c)?));
                    while h.entries.len() > 512 {
                        h.entries.pop_front();
                    }
                }
            }
            h.seen = ids;
            let cursor = j["cursor"].as_u64().unwrap_or(0);
            let mut next = cursor;
            let rows: Vec<_> = h
                .entries
                .iter()
                .filter(|(n, _)| *n > cursor)
                .take(limit)
                .map(|(n, v)| {
                    next = *n;
                    v.clone()
                })
                .collect();
            let dropped = h
                .entries
                .front()
                .is_some_and(|(n, _)| cursor > 0 && cursor + 1 < *n);
            Ok(json!({"cursor":next,"dropped":dropped,"connections":rows}))
        }
        _ => unreachable!(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request(home: &Path, source: &str, namespace: &str) -> J {
        json!({"yaml":source,"home":home,"cacheNamespace":namespace,"settings":{"geoEnabled":false},"mixedPort":23456,"dnsPort":23457})
    }
    #[test]
    fn abi_errors_are_owned_json() {
        let pointer = unsafe { cora_core_request(std::ptr::null(), 0) };
        assert!(!pointer.is_null());
        let value: J = serde_json::from_str(
            unsafe { std::ffi::CStr::from_ptr(pointer) }
                .to_str()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(value["ok"], false);
        unsafe { crate::meow_string_free(pointer) };
    }
    #[test]
    fn prepare_keeps_source_dns_and_success_file_immutable() {
        let home = tempfile::tempdir().unwrap();
        let source="# original\ndns: {nameserver: ['https://example.org/dns-query']}\nrules: ['MATCH,DIRECT']\n";
        let file = home.path().join("config.yaml");
        std::fs::write(&file, source).unwrap();
        let previous = home.path().join("meow-last-success.json");
        std::fs::write(&previous, "last-good").unwrap();
        let result = prepare(&request(home.path(), source, &"a".repeat(64))).unwrap();
        let doc = cora_config::parse(text(&result, "yaml")).unwrap();
        assert_eq!(doc["dns"]["nameserver"].as_sequence().unwrap().len(), 1);
        assert_eq!(doc["dns"]["enhanced-mode"].as_str(), Some("fake-ip"));
        assert!(doc.get("sniffer").is_none());
        assert_eq!(doc["skip-auth-prefixes"][0].as_str(), Some("127.0.0.0/8"));
        assert!(doc.get("subscriptions").is_none());
        assert!(doc["secret"].as_str().unwrap().len() >= 64);
        assert!(doc["external-controller"]
            .as_str()
            .unwrap()
            .starts_with("127.0.0.1:"));
        assert!(prepare(&request(
            home.path(),
            "dns: {respect-rules: true}",
            &"a".repeat(64)
        ))
        .is_err());
        assert_eq!(std::fs::read_to_string(file).unwrap(), source);
        assert_eq!(std::fs::read_to_string(previous).unwrap(), "last-good");
    }
    #[test]
    fn caches_are_profile_isolated_and_original_not_seeded() {
        let home = tempfile::tempdir().unwrap();
        let original = home.path().join("nodes.yaml");
        std::fs::write(&original, "ORIGINAL").unwrap();
        let source="proxy-providers: {p: {type: http, url: 'https://example.org', path: ./nodes.yaml}}\nrules: ['MATCH,DIRECT']";
        let a = prepare(&request(home.path(), source, &"a".repeat(64))).unwrap();
        let b = prepare(&request(home.path(), source, &"b".repeat(64))).unwrap();
        let a = cora_config::parse(text(&a, "yaml")).unwrap();
        let b = cora_config::parse(text(&b, "yaml")).unwrap();
        assert_ne!(
            a["proxy-providers"]["p"]["path"],
            b["proxy-providers"]["p"]["path"]
        );
        assert!(!home
            .path()
            .join(a["proxy-providers"]["p"]["path"].as_str().unwrap())
            .exists());
        assert_eq!(std::fs::read_to_string(original).unwrap(), "ORIGINAL");
    }
    #[test]
    fn inline_provider_materializes_copy_and_preserves_use() {
        let home = tempfile::tempdir().unwrap();
        let source="proxy-providers: {p: {type: inline, payload: [{name: A, type: ss, server: example.org, port: 443, cipher: aes-128-gcm, password: x}]}}\nproxy-groups: [{name: G, type: select, use: [p]}]\nrules: ['MATCH,G']";
        let result = prepare(&request(home.path(), source, &"a".repeat(64))).unwrap();
        let doc = cora_config::parse(text(&result, "yaml")).unwrap();
        assert_eq!(doc["proxy-groups"][0]["use"][0].as_str(), Some("p"));
        let path = doc["proxy-providers"]["p"]["path"].as_str().unwrap();
        assert_eq!(
            cora_config::provider_nodes(&std::fs::read_to_string(home.path().join(path)).unwrap())
                .unwrap()
                .len(),
            1
        );
        assert!(source.contains("type: inline"));
    }
    #[test]
    fn unknown_fields_include_yaml_path() {
        assert!(checked_shape("dns: {mystery: true}")
            .unwrap_err()
            .to_string()
            .contains("$.dns.mystery"));
        assert!(checked_shape("sniffer: {sniff: {QUIC: {ports: [443]}}}")
            .unwrap_err()
            .to_string()
            .contains("$.sniffer.sniff.QUIC"));
    }
    #[test]
    fn runtime_auth_and_sniffer_do_not_change_source_semantics() {
        let home = tempfile::tempdir().unwrap();
        let source =
            "authentication: ['user:password']\nsniffer: {enable: false}\nrules: ['MATCH,DIRECT']";
        let result = prepare(&request(home.path(), source, &"a".repeat(64))).unwrap();
        let doc = cora_config::parse(text(&result, "yaml")).unwrap();
        assert_eq!(doc["authentication"][0].as_str(), Some("user:password"));
        assert_eq!(doc["sniffer"]["enable"].as_bool(), Some(false));
        assert_eq!(doc["bind-address"].as_str(), Some("127.0.0.1"));
        assert_eq!(doc["allow-lan"].as_bool(), Some(false));
    }
    #[test]
    fn offline_same_named_provider_nodes_remain_source_scoped() {
        let home = tempfile::tempdir().unwrap();
        let source = "proxy-providers: {one: {type: http, url: 'https://one.invalid/nodes'}, two: {type: http, url: 'https://two.invalid/nodes'}}\nproxy-groups: [{name: G, type: select, use: [one, two]}]\nrules: ['MATCH,G']";
        let payload = "proxies: [{name: Same, type: ss, server: localhost, port: 443, cipher: aes-128-gcm, password: test}]";
        let running_before = engine::tunnel().is_some();
        let result = offline(&json!({"yaml":source,"home":home.path(),"cacheNamespace":"a".repeat(64),"providers":{"one":payload,"two":payload}})).unwrap();
        let nodes = result["providerNodes"].as_array().unwrap();
        assert_eq!(nodes.len(), 2);
        assert!(nodes.iter().all(|n| n["name"] == "Same"));
        assert_eq!(
            nodes
                .iter()
                .map(|n| n["provider-name"].as_str().unwrap())
                .collect::<HashSet<_>>(),
            HashSet::from(["one", "two"])
        );
        assert_eq!(engine::tunnel().is_some(), running_before);
    }
    #[test]
    fn prepared_runtime_starts_with_internal_socks_and_packet_callbacks() {
        use std::io::{Read, Write};
        use std::net::{TcpListener, TcpStream};
        use std::time::Duration;
        unsafe extern "C" fn discard(_: *mut std::ffi::c_void, _: *const u8, _: usize) {}
        struct Stop;
        impl Drop for Stop {
            fn drop(&mut self) {
                crate::meow_tun_stop_blocking();
                crate::meow_engine_stop();
            }
        }
        let home = tempfile::tempdir().unwrap();
        let dir = CString::new(home.path().to_str().unwrap()).unwrap();
        unsafe { crate::meow_core_set_home_dir(dir.as_ptr()) };
        let mixed = TcpListener::bind("127.0.0.1:0").unwrap();
        let dns = TcpListener::bind("127.0.0.1:0").unwrap();
        let mixed_port = mixed.local_addr().unwrap().port();
        let mut input = request(
            home.path(),
            "authentication: ['user:password']\nrules: ['MATCH,DIRECT']",
            &"a".repeat(64),
        );
        input["mixedPort"] = json!(mixed_port);
        input["dnsPort"] = json!(dns.local_addr().unwrap().port());
        let prepared = prepare(&input).unwrap();
        let config = home.path().join("runtime.yaml");
        std::fs::write(&config, text(&prepared, "yaml")).unwrap();
        let path = CString::new(config.to_str().unwrap()).unwrap();
        drop((mixed, dns));
        let _stop = Stop;
        assert_eq!(unsafe { crate::meow_engine_start(path.as_ptr()) }, 0);
        // Check actual loopback SOCKS negotiation, including an authenticated
        // source config, before feeding packets into the native generation.
        let deadline = Instant::now() + Duration::from_secs(3);
        let mut socket = loop {
            match TcpStream::connect((std::net::Ipv4Addr::LOCALHOST, mixed_port)) {
                Ok(s) => break s,
                Err(e) => {
                    assert!(Instant::now() < deadline, "mixed listener: {e}");
                    std::thread::sleep(Duration::from_millis(10));
                }
            }
        };
        socket
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        socket.write_all(&[5, 1, 0]).unwrap();
        let mut reply = [0; 2];
        socket.read_exact(&mut reply).unwrap();
        assert_eq!(reply, [5, 0]);
        drop(socket);
        assert_eq!(
            unsafe { crate::meow_tun_start(std::ptr::null_mut(), discard) },
            0
        );
        let src = CString::new("198.18.0.1").unwrap();
        let dst = CString::new("198.18.0.2").unwrap();
        assert_eq!(
            unsafe { crate::meow_tun_health_probe(src.as_ptr(), dst.as_ptr(), 3000) },
            0
        );
    }
    #[test]
    fn provider_download_headers_and_failed_refresh_keep_last_good_bytes() {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        use std::time::Duration;
        let home = tempfile::tempdir().unwrap();
        let server = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = server.local_addr().unwrap();
        server.set_nonblocking(true).unwrap();
        let payload = "proxies: [{name: A, type: ss, server: localhost, port: 443, cipher: aes-128-gcm, password: test}]\n";
        let handle = std::thread::spawn(move || {
            for response in [
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
                    payload.len()
                ),
                "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into(),
            ] {
                let deadline = Instant::now() + Duration::from_secs(5);
                let mut socket = loop {
                    match server.accept() {
                        Ok((s, _)) => break s,
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            assert!(Instant::now() < deadline, "HTTP request did not arrive");
                            std::thread::sleep(Duration::from_millis(10));
                        }
                        Err(e) => panic!("{e}"),
                    }
                };
                socket
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut bytes = Vec::new();
                let mut buf = [0; 1024];
                while !bytes.windows(4).any(|w| w == b"\r\n\r\n") {
                    let n = socket.read(&mut buf).unwrap();
                    assert!(n > 0 && bytes.len() + n < 8192);
                    bytes.extend_from_slice(&buf[..n]);
                }
                assert!(String::from_utf8(bytes)
                    .unwrap()
                    .to_lowercase()
                    .contains("x-cora-test: fixture"));
                socket.write_all(response.as_bytes()).unwrap();
            }
        });
        let original = home.path().join("original-provider.yaml");
        std::fs::write(&original, "original bytes").unwrap();
        let source = format!("proxy-providers: {{p: {{type: http, url: 'http://{address}/nodes', path: './original-provider.yaml', header: {{X-Cora-Test: [fixture]}}}}}}\nproxy-groups: [{{name: G, type: select, use: [p]}}]\nrules: ['MATCH,G']");
        let prepared = prepare(&request(home.path(), &source, &"a".repeat(64))).unwrap();
        let config = home.path().join("runtime.yaml");
        std::fs::write(&config, text(&prepared, "yaml")).unwrap();
        let cfg = get_engine_runtime()
            .block_on(meow_config::load_config(config.to_str().unwrap()))
            .unwrap();
        let provider = &cfg.proxy_providers["p"];
        assert_eq!(provider.proxies().len(), 1);
        let doc = cora_config::parse(text(&prepared, "yaml")).unwrap();
        let cache = home
            .path()
            .join(doc["proxy-providers"]["p"]["path"].as_str().unwrap());
        let good = std::fs::read(&cache).unwrap();
        assert_eq!(good, payload.as_bytes());
        assert!(get_engine_runtime().block_on(provider.refresh()).is_err());
        assert_eq!(provider.proxies().len(), 1);
        assert_eq!(std::fs::read(&cache).unwrap(), good);
        assert_eq!(std::fs::read_to_string(original).unwrap(), "original bytes");
        handle.join().unwrap();
    }
    #[test]
    fn inline_rules_are_text_but_mrs_never_lossy_decoded() {
        let result=rule_content(&json!({"yaml":"rule-providers: {p: {type: inline, payload: ['DOMAIN,a.example']}}","name":"p"})).unwrap();
        assert_eq!(result["content"], "DOMAIN,a.example");
        assert!(rule_content(
            &json!({"yaml":"rule-providers: {p: {type: file, format: mrs}}","name":"p"})
        )
        .is_err());
    }
    #[cfg(unix)]
    #[test]
    fn symlink_file_provider_cannot_escape_home() {
        let home = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("nodes.yaml"), "proxies: []").unwrap();
        std::os::unix::fs::symlink(outside.path(), home.path().join("escape")).unwrap();
        assert!(safe_file(home.path(), "escape/nodes.yaml").is_err());
    }
}
