//! Offline lookups of where an IP is registered — its country (or the
//! MetaCubeX special code, e.g. `GOOGLE`, `PRIVATE`) and the network (ASN)
//! that owns it — in the GeoX databases `GeoAssetStager` stages into the
//! App Group config dir. Backs the connection detail page's IP section, so
//! it runs in the app process and needs no engine: nothing leaves the
//! device. The C ABI lives in `lib.rs` (`meow_lookup_ip`).
//!
//! Ported from meow-android's `ip_info` module.

use maxminddb::{Mmap, PathElement, Reader};
use parking_lot::Mutex;
use serde::Serialize;
use std::fs::Metadata;
use std::net::IpAddr;
#[cfg(unix)]
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

/// The engine's discovery names (`meow_config::default_geoip_path`), as
/// staged by `GeoAssetStager`.
const COUNTRY_DB: &str = "geoip.metadb";
const ASN_DB: &str = "ASN.mmdb";

#[derive(Debug, Default, PartialEq, Serialize)]
pub(crate) struct IpInfo {
    #[serde(skip_serializing_if = "Option::is_none")]
    country: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    asn: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    org: Option<String>,
}

/// One open database and the file it was mapped from. A new app build
/// restages the file (temp file + rename), which changes the inode, so the
/// next lookup maps the new one.
struct Db {
    path: PathBuf,
    stamp: (u64, u64, i64, i64),
    reader: Reader<Mmap>,
}

static COUNTRY: Mutex<Option<Db>> = Mutex::new(None);
static ASN: Mutex<Option<Db>> = Mutex::new(None);

#[cfg(unix)]
fn stamp(meta: &Metadata) -> (u64, u64, i64, i64) {
    (meta.ino(), meta.len(), meta.mtime(), meta.mtime_nsec())
}
#[cfg(not(unix))]
fn stamp(meta: &Metadata) -> (u64, u64, i64, i64) {
    let modified = meta
        .modified()
        .ok()
        .and_then(|d| d.duration_since(std::time::UNIX_EPOCH).ok())
        .unwrap_or_default();
    (
        0,
        meta.len(),
        modified.as_secs() as i64,
        modified.subsec_nanos() as i64,
    )
}

/// Runs `f` on the database at `path`, mapping it on first use and again
/// after the file is replaced. None when it is missing or unreadable.
fn with_db<T>(
    slot: &Mutex<Option<Db>>,
    path: &Path,
    f: impl FnOnce(&Reader<Mmap>) -> Option<T>,
) -> Option<T> {
    let stamp = stamp(&std::fs::metadata(path).ok()?);
    let mut slot = slot.lock();
    let fresh = slot
        .as_ref()
        .is_some_and(|db| db.path == path && db.stamp == stamp);
    if !fresh {
        *slot = None;
        // SAFETY: nothing rewrites these files in place. `GeoAssetStager`
        // replaces a database by writing a sibling and renaming it over,
        // which leaves this mapping on the old inode, and the engine's own
        // geodata updater is disabled on iOS.
        let reader = unsafe { Reader::open_mmap(path) }.ok()?;
        *slot = Some(Db {
            path: path.to_owned(),
            stamp,
            reader,
        });
    }
    f(&slot.as_ref()?.reader)
}

fn country(reader: &Reader<impl AsRef<[u8]>>, ip: IpAddr) -> Option<String> {
    let found = reader.lookup(ip).ok()?;
    // Fall back to where the block is registered: anycast and satellite
    // ranges carry only that.
    ["country", "registered_country"].iter().find_map(|key| {
        let code = found
            .decode_path::<&str>(&[PathElement::Key(key), PathElement::Key("iso_code")])
            .ok()??;
        (!code.is_empty()).then(|| code.to_owned())
    })
}

fn asn(reader: &Reader<impl AsRef<[u8]>>, ip: IpAddr) -> (Option<u32>, Option<String>) {
    let Some(found) = reader.lookup(ip).ok() else {
        return (None, None);
    };
    let number = found
        .decode_path::<u32>(&[PathElement::Key("autonomous_system_number")])
        .ok()
        .flatten();
    let org = found
        .decode_path::<&str>(&[PathElement::Key("autonomous_system_organization")])
        .ok()
        .flatten()
        .filter(|org| !org.is_empty())
        .map(str::to_owned);
    (number, org)
}

pub(crate) fn lookup(dir: &Path, ip: IpAddr) -> IpInfo {
    let ip = ip.to_canonical();
    let country = with_db(&COUNTRY, &dir.join(COUNTRY_DB), |r| country(r, ip));
    let (asn, org) = with_db(&ASN, &dir.join(ASN_DB), |r| Some(asn(r, ip))).unwrap_or_default();
    IpInfo { country, asn, org }
}

/// `{"country": "CN", "asn": 136958, "org": "…"}` for `ip`, looked up in the
/// databases under `dir`; fields it has no answer for are left out, so an
/// unparseable IP, or a panic, gets `{}`.
pub(crate) fn lookup_json(dir: &str, ip: &str) -> String {
    let info = std::panic::catch_unwind(|| {
        ip.trim()
            .parse::<IpAddr>()
            .map(|ip| lookup(Path::new(dir), ip))
            .unwrap_or_default()
    })
    .unwrap_or_default();
    serde_json::to_string(&info).unwrap_or_else(|_| "{}".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The databases the app bundles (`App/Resources/GeoData`).
    fn geo_dir() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../App/Resources/GeoData")
    }

    #[test]
    fn missing_databases_answer_nothing() {
        let dir = std::env::temp_dir().join("meow-ip-info-missing");
        assert_eq!(lookup(&dir, "8.8.8.8".parse().unwrap()), IpInfo::default());
        assert_eq!(serde_json::to_string(&IpInfo::default()).unwrap(), "{}");
    }

    #[test]
    fn unparseable_ip_answers_nothing() {
        let dir = geo_dir();
        assert_eq!(lookup_json(dir.to_str().unwrap(), "not an ip"), "{}");
        assert_eq!(lookup_json(dir.to_str().unwrap(), ""), "{}");
    }

    #[test]
    fn looks_up_self_contained_country_fixture() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(
            dir.path().join(COUNTRY_DB),
            include_bytes!("../tests/fixtures/GeoIP2-Country-Test.mmdb"),
        )
        .unwrap();
        let info = lookup(dir.path(), "214.78.120.1".parse().unwrap());
        assert_eq!(info.country.as_deref(), Some("US"));
        assert_eq!(info.asn, None);
        assert_eq!(
            lookup(dir.path(), "::ffff:214.78.120.1".parse().unwrap()),
            info
        );
    }
}
