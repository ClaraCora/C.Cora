//! Cora 解锁检测脚本端点（ScriptFetch / ScriptTargetInfo / DirectNetworkInfo）
//! 的 meow-rs 移植。请求始终经指定代理适配器发出——不走系统直连、不经过
//! 规则引擎——与 Go 版（MobileCore/mihomo.go）语义一致。

use anyhow::{anyhow, Result};
use cora_config::script as cs;
use meow_common::{AdapterType, ConnType, Metadata, Network, Proxy, ProxyAdapter};
use meow_transport::tls::{TlsConfig, TlsLayer};
use parking_lot::Mutex;
use serde_json::{json, Map as JM, Value as J};
use std::collections::{HashMap, HashSet};
use std::io::Write as _;
use std::net::IpAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const MAX_REDIRECTS: usize = 4;
const DIRECT_INFO_ENDPOINTS: [(&str, &str); 3] = [
    ("https://myip.ipip.net", "ipip.net"),
    ("https://api.ip.sb/geoip", "ip.sb"),
    ("https://ipwho.is/", "ipwho.is"),
];

fn err_json(message: impl Into<String>) -> J {
    json!({"ok": false, "error": message.into()})
}

// ---------------------------------------------------------------------------
// 代理解析（mihomo resolveScriptProxyDepth）
// ---------------------------------------------------------------------------

fn resolve_script_proxy(
    proxies: &HashMap<smol_str::SmolStr, Arc<dyn Proxy>>,
    name: &str,
    group: &str,
    visited: &mut HashSet<String>,
    depth: u32,
) -> std::result::Result<Arc<dyn Proxy>, String> {
    if depth > 12 {
        return Err("策略组引用层级过深".into());
    }
    let name = name.trim();
    let group = group.trim();
    if !name.is_empty() {
        if let Some(proxy) = proxies.get(name) {
            if !visited.insert(name.to_string()) {
                return Err("策略组引用存在循环".into());
            }
            if proxy.member_proxies().is_some() {
                let selected = proxy.current().unwrap_or_default();
                let selected = selected.trim();
                if selected.is_empty() {
                    return Err("策略组没有当前节点".into());
                }
                return resolve_script_proxy(proxies, selected, name, visited, depth + 1);
            }
            return Ok(Arc::clone(proxy));
        }
        if let Some(parent) = proxies.get(group) {
            if let Some(members) = parent.member_proxies() {
                if let Some(member) = members.iter().find(|m| m.name() == name) {
                    return Ok(Arc::clone(member));
                }
            }
        }
        return Err("节点不存在".into());
    }
    if let Some(parent) = proxies.get(group) {
        if parent.member_proxies().is_none() {
            return Err("目标不是策略组".into());
        }
        let selected = parent.current().unwrap_or_default();
        let selected = selected.trim();
        if selected.is_empty() {
            return Err("策略组没有当前节点".into());
        }
        return resolve_script_proxy(proxies, selected, group, visited, depth + 1);
    }
    Err("没有指定测试节点".into())
}

fn resolve_for_script(name: &str, group: &str) -> std::result::Result<(Arc<meow_tunnel::tunnel::RouteTable>, Arc<dyn Proxy>), String> {
    let Some(tunnel) = crate::engine::tunnel() else {
        return Err("内核未运行".into());
    };
    let route = tunnel.route_snapshot();
    let proxy = resolve_script_proxy(&route.proxies, name, group, &mut HashSet::new(), 0)?;
    Ok((route, proxy))
}

fn usable_for_unlock_test(proxy: &Arc<dyn Proxy>) -> bool {
    !matches!(
        proxy.adapter_type(),
        AdapterType::Direct | AdapterType::Reject | AdapterType::RejectDrop
    )
}

// ---------------------------------------------------------------------------
// 经适配器的 HTTPS 请求
// ---------------------------------------------------------------------------

struct ScriptResponse {
    status: u16,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
    truncated: bool,
}

const RESERVED_HEADERS: [&str; 12] = [
    "host",
    "connection",
    "content-length",
    "accept-encoding",
    "transfer-encoding",
    "trailer",
    "te",
    "upgrade",
    "keep-alive",
    "proxy-connection",
    "proxy-authenticate",
    "proxy-authorization",
];

/// One bounded HTTPS exchange through `adapter`. Mirrors the Go transport:
/// dial the proxy for the URL's host, wrap in TLS, speak HTTP/1.1 with
/// `Connection: close`, read to EOF with a hard cap.
async fn fetch_once(
    adapter: &dyn ProxyAdapter,
    method: &str,
    url: &url::Url,
    headers: &[(String, String)],
    body: &[u8],
) -> Result<ScriptResponse> {
    let host = url
        .host_str()
        .ok_or_else(|| anyhow!("脚本请求地址缺少主机名"))?
        .to_string();
    let port = url.port_or_known_default().unwrap_or(443);
    let metadata = Metadata {
        network: Network::Tcp,
        conn_type: ConnType::Http,
        host: host.as_str().into(),
        dst_port: port,
        // 脚本请求属于诊断流量，不应计入 lazy 策略组的使用统计。
        internal: true,
        ..Default::default()
    };
    let conn = adapter
        .dial_tcp(&metadata)
        .await
        .map_err(|e| anyhow!("节点连接失败: {e}"))?;
    let tls = TlsLayer::new(&TlsConfig::new(host.trim_start_matches('[').trim_end_matches(']')))
        .map_err(|e| anyhow!("TLS 配置失败: {e}"))?;
    let mut stream = tls
        .connect(Box::new(conn))
        .await
        .map_err(|e| anyhow!("TLS 握手失败: {e}"))?;

    let path = match url.query() {
        Some(query) => format!("{}?{query}", url.path()),
        None => {
            let path = url.path();
            if path.is_empty() { "/".to_string() } else { path.to_string() }
        }
    };
    let host_header = if port == 443 { host.clone() } else { format!("{host}:{port}") };
    let mut request = format!("{method} {path} HTTP/1.1\r\nHost: {host_header}\r\nConnection: close\r\n");
    for (name, value) in headers {
        if RESERVED_HEADERS.iter().any(|r| name.eq_ignore_ascii_case(r)) {
            continue;
        }
        request.push_str(name);
        request.push_str(": ");
        request.push_str(value);
        request.push_str("\r\n");
    }
    if !body.is_empty() && method != "HEAD" {
        write!(request, "Content-Length: {}\r\n", body.len()).map_err(|e| anyhow!("请求构造失败: {e}"))?;
    }
    request.push_str("\r\n");
    stream
        .write_all(request.as_bytes())
        .await
        .and_then(|()| stream.flush())
        .map_err(|e| anyhow!("发送请求失败: {e}"))?;
    if !body.is_empty() && method != "HEAD" {
        stream.write_all(body).await.and_then(|()| stream.flush()).map_err(|e| anyhow!("发送请求体失败: {e}"))?;
    }

    let read_cap = cs::MAX_SCRIPT_RESPONSE_BODY_BYTES + 64 * 1024;
    let mut buf = Vec::with_capacity(64 * 1024);
    let mut tmp = [0u8; 16 * 1024];
    loop {
        let n = stream.read(&mut tmp).await.map_err(|e| anyhow!("读取响应失败: {e}"))?;
        if n == 0 {
            break;
        }
        if buf.len() + n > read_cap {
            buf.extend_from_slice(&tmp[..read_cap - buf.len()]);
            break;
        }
        buf.extend_from_slice(&tmp[..n]);
    }
    parse_response(&buf, method == "HEAD")
}

fn parse_response(buf: &[u8], head_only: bool) -> Result<ScriptResponse> {
    let mut headers = [httparse::EMPTY_HEADER; 64];
    let mut resp = httparse::Response::new(&mut headers);
    let body_start = match resp
        .parse(buf)
        .map_err(|e| anyhow!("响应解析失败: {e}"))?
    {
        httparse::Status::Complete(n) => n,
        httparse::Status::Partial => return Err(anyhow!("响应头不完整")),
    };
    let status = resp.code.ok_or_else(|| anyhow!("响应缺少状态码"))?;
    let mut collected: Vec<(String, String)> = Vec::new();
    let mut header_bytes = 0usize;
    for header in resp.headers.iter() {
        if header.name.len() > 256 {
            continue;
        }
        let Ok(value) = std::str::from_utf8(header.value) else { continue };
        let value = value.trim();
        if value.len() > 8 << 10 || header_bytes + header.name.len() + value.len() > cs::MAX_SCRIPT_RESPONSE_HEADER_BYTES {
            continue;
        }
        header_bytes += header.name.len() + value.len();
        // 同名头按 Go http.Header 的写法合并为一个逗号分隔值。
        if let Some(existing) = collected.iter_mut().find(|(k, _)| k.eq_ignore_ascii_case(header.name)) {
            existing.1.push_str(", ");
            existing.1.push_str(value);
        } else {
            collected.push((header.name.to_string(), value.to_string()));
        }
    }
    let raw = &buf[body_start.min(buf.len())..];
    let (body, truncated) = if head_only || status == 204 || status == 304 {
        (Vec::new(), false)
    } else {
        let chunked = collected.iter().any(|(k, v)| {
            k.eq_ignore_ascii_case("transfer-encoding")
                && v.split(',').any(|part| part.trim().eq_ignore_ascii_case("chunked"))
        });
        if chunked {
            decode_chunked_truncating(raw, cs::MAX_SCRIPT_RESPONSE_BODY_BYTES)
        } else if raw.len() > cs::MAX_SCRIPT_RESPONSE_BODY_BYTES {
            (raw[..cs::MAX_SCRIPT_RESPONSE_BODY_BYTES].to_vec(), true)
        } else {
            (raw.to_vec(), false)
        }
    };
    Ok(ScriptResponse { status, headers: collected, body, truncated })
}

/// Chunked decoding that truncates at `limit` instead of failing; the Go
/// implementation capped the reader and reported `truncated`.
fn decode_chunked_truncating(mut input: &[u8], limit: usize) -> (Vec<u8>, bool) {
    let mut body = Vec::new();
    loop {
        let Some(line_end) = input.windows(2).position(|w| w == b"\r\n") else {
            return (body, true);
        };
        let Ok(size_text) = std::str::from_utf8(&input[..line_end]) else {
            return (body, true);
        };
        let Ok(size) = usize::from_str_radix(size_text.split(';').next().unwrap_or_default().trim(), 16) else {
            return (body, true);
        };
        input = &input[line_end + 2..];
        if size == 0 {
            return (body, false);
        }
        if input.len() < size + 2 {
            body.extend_from_slice(&input[..input.len().min(size)]);
            return (body[..body.len().min(limit)].to_vec(), true);
        }
        let keep = size.min(limit.saturating_sub(body.len()));
        body.extend_from_slice(&input[..keep]);
        if keep < size {
            return (body, true);
        }
        input = &input[size + 2..];
    }
}

fn is_redirect(status: u16) -> bool {
    matches!(status, 301 | 302 | 303 | 307 | 308)
}

fn location_of(headers: &[(String, String)]) -> Option<&str> {
    headers
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case("location"))
        .map(|(_, v)| v.as_str())
}

async fn fetch_following_redirects(
    adapter: &dyn ProxyAdapter,
    request: &cs::ScriptRequest,
) -> Result<ScriptResponse> {
    let mut url = url::Url::parse(&request.url).map_err(|e| anyhow!("脚本只允许 HTTPS 请求: {e}"))?;
    let mut method = request.method.clone();
    let mut body = if method == "HEAD" { Vec::new() } else { request.body.clone().into_bytes() };
    let mut redirects = 0usize;
    loop {
        let response = fetch_once(adapter, &method, &url, &request.headers, &body).await?;
        if !request.allow_redirect || !is_redirect(response.status) {
            return Ok(response);
        }
        if redirects >= MAX_REDIRECTS {
            return Ok(response);
        }
        let Some(location) = location_of(&response.headers) else {
            return Ok(response);
        };
        let Ok(next) = url.join(location) else {
            return Ok(response);
        };
        // 与 Go 一致：只允许停留在 HTTPS，避免把凭据带往降级地址。
        if next.scheme() != "https" {
            return Ok(response);
        }
        // Go http.Client：301/302/303 把 POST 换成 GET 并丢弃请求体；HEAD 保持。
        if response.status == 303 || (matches!(response.status, 301 | 302) && method == "POST") {
            method = "GET".to_string();
            body = Vec::new();
        }
        url = next;
        redirects += 1;
    }
}

fn headers_json(headers: &[(String, String)]) -> J {
    let mut map = JM::new();
    for (name, value) in headers {
        map.insert(name.clone(), json!(value));
    }
    J::Object(map)
}

// ---------------------------------------------------------------------------
// IPC 入口
// ---------------------------------------------------------------------------

pub fn fetch(j: &J) -> Result<J> {
    let request = match cs::validate_script_request(&j["request"]) {
        Ok(request) => request,
        Err(e) => return Ok(err_json(e)),
    };
    let (_route, proxy) = match resolve_for_script(&request.name, &request.group) {
        Ok(value) => value,
        Err(e) => return Ok(err_json(e)),
    };
    if !usable_for_unlock_test(&proxy) {
        return Ok(err_json("目标不是可用于解锁测试的代理节点"));
    }
    let timeout = Duration::from_millis(request.timeout_ms);
    let adapter: &dyn ProxyAdapter = proxy.as_ref();
    let outcome = crate::get_engine_runtime().block_on(async move {
        tokio::time::timeout(timeout, fetch_following_redirects(adapter, &request)).await
    });
    Ok(match outcome {
        Ok(Ok(response)) => json!({
            "ok": true,
            "status": response.status,
            "headers": headers_json(&response.headers),
            "body": String::from_utf8_lossy(&response.body),
            "truncated": response.truncated,
        }),
        Ok(Err(e)) => err_json(format!("节点请求超时或失败（{e}）")),
        Err(_) => err_json("节点请求超时或失败"),
    })
}

pub fn direct_network_info() -> Result<J> {
    let Some(tunnel) = crate::engine::tunnel() else {
        return Ok(err_json("内核未运行"));
    };
    let route = tunnel.route_snapshot();
    let Some(direct) = route.proxies.get("DIRECT") else {
        return Ok(err_json("DIRECT 出站不可用"));
    };
    if direct.adapter_type() != AdapterType::Direct {
        return Ok(err_json("DIRECT 出站不可用"));
    }
    let adapter: &dyn ProxyAdapter = direct.as_ref();
    let headers = [
        ("User-Agent".to_string(), "Cora/1.0 NetworkInfo".to_string()),
        ("Accept".to_string(), "application/json, text/plain;q=0.9".to_string()),
    ];
    let outcome = crate::get_engine_runtime().block_on(async move {
        for (endpoint, name) in DIRECT_INFO_ENDPOINTS {
            let Ok(url) = url::Url::parse(endpoint) else { continue };
            let attempt = tokio::time::timeout(
                Duration::from_secs(8),
                fetch_once(adapter, "GET", &url, &headers, &[]),
            )
            .await;
            let Ok(Ok(response)) = attempt else { continue };
            if !(200..300).contains(&response.status) {
                continue;
            }
            if let Some(mut info) = cs::parse_direct_network_info(&response.body) {
                info["ok"] = json!(true);
                info["provider"] = json!(name);
                return Ok::<J, anyhow::Error>(info);
            }
        }
        Ok(err_json("直连公网信息查询失败"))
    });
    outcome
}

// ---------------------------------------------------------------------------
// ScriptTargetInfo（含 15 分钟新鲜 / 6 小时兜底 / 128 条的会话级缓存）
// ---------------------------------------------------------------------------

struct TargetIpEntry {
    ip: String,
    fresh_until: Instant,
    expires_at: Instant,
}

static TARGET_IP_CACHE: Mutex<Option<HashMap<String, TargetIpEntry>>> = Mutex::new(None);

fn cache_lookup(host: &str, allow_stale: bool) -> Option<String> {
    let now = Instant::now();
    let cache = TARGET_IP_CACHE.lock();
    let entry = cache.as_ref()?.get(host)?;
    if now < entry.fresh_until || (allow_stale && now < entry.expires_at) {
        Some(entry.ip.clone())
    } else {
        None
    }
}

fn cache_store(host: &str, ip: String) {
    let now = Instant::now();
    let mut cache = TARGET_IP_CACHE.lock();
    let cache = cache.get_or_insert_with(HashMap::new);
    if !cache.contains_key(host) && cache.len() >= 128 {
        cache.retain(|_, entry| now < entry.expires_at);
        if cache.len() >= 128 {
            if let Some(oldest) = cache.keys().next().cloned() {
                cache.remove(&oldest);
            }
        }
    }
    cache.insert(
        host.to_string(),
        TargetIpEntry {
            ip,
            fresh_until: now + Duration::from_secs(15 * 60),
            expires_at: now + Duration::from_secs(6 * 3600),
        },
    );
}

pub fn clear_target_ip_cache() {
    *TARGET_IP_CACHE.lock() = None;
}

pub fn target_info(j: &J) -> Result<J> {
    let name = j["name"].as_str().unwrap_or("");
    let group = j["group"].as_str().unwrap_or("");
    let (_route, proxy) = match resolve_for_script(name, group) {
        Ok(value) => value,
        Err(e) => return Ok(err_json(e)),
    };
    if !usable_for_unlock_test(&proxy) {
        return Ok(err_json("目标不是可查询入口的代理节点"));
    }
    let address = proxy.addr().trim().to_string();
    let (host, port) = cs::split_target_address(&address);
    let mut result = json!({
        "ok": true,
        "node": proxy.name(),
        "address": address,
        "host": host,
        "port": port,
    });
    if host.is_empty() {
        return Ok(result);
    }
    if let Ok(ip) = host.parse::<IpAddr>() {
        if cs::usable_target_ip(&ip) {
            result["ip"] = json!(ip.to_string());
        } else {
            result["resolutionError"] = json!("节点入口不是可查询的公网地址");
        }
        return Ok(result);
    }
    let key = host.to_lowercase();
    if let Some(ip) = cache_lookup(&key, false) {
        result["ip"] = json!(ip);
        return Ok(result);
    }
    let resolve = async {
        match tokio::time::timeout(Duration::from_secs(5), meow_common::resolve_host_all(&host, 0)).await {
            Ok(Ok(addrs)) => {
                let mut v6: Option<IpAddr> = None;
                for addr in addrs {
                    let ip = addr.ip();
                    if !cs::usable_target_ip(&ip) {
                        continue;
                    }
                    if ip.is_ipv4() {
                        return Ok(ip);
                    }
                    v6.get_or_insert(ip);
                }
                match v6 {
                    Some(ip) => Ok(ip),
                    None => Err("节点入口没有可用 IP 地址".to_string()),
                }
            }
            _ => Err("节点入口域名暂时无法解析".to_string()),
        }
    };
    let resolved = crate::get_engine_runtime().block_on(resolve);
    match resolved {
        Ok(ip) => {
            let text = ip.to_string();
            cache_store(&key, text.clone());
            result["ip"] = json!(text);
        }
        Err(e) => {
            if let Some(ip) = cache_lookup(&key, true) {
                result["ip"] = json!(ip);
                result["resolutionError"] = json!("节点入口 DNS 暂时不可用，沿用上次解析结果");
            } else {
                result["resolutionError"] = json!(e);
            }
        }
    }
    Ok(result)
}

/// 引擎停止时清掉会话级解析缓存（与 Go `clearScriptTargetIPCache` 一致）。
pub fn on_engine_stopped() {
    clear_target_ip_cache();
}
