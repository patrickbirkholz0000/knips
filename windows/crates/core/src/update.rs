//! Automatische Aktualisierung der Windows-Fassung: wann Knips bei GitHub nach einer neuen Version fragt.
//! Hier steht nur, was ohne Netz und ohne Windows geht — welche Sitzung überhaupt fragen darf, wann die nächste
//! Suche fällig ist, ob eine Version neuer ist. Suchen, Laden, Prüfen und Installieren über `tauri-plugin-updater`:
//! `src-tauri/src/update.rs`.
//!
//! Feed und öffentlicher Schlüssel stehen in `src-tauri/tauri.conf.json` (`plugins.updater`). Der Test
//! `release_config` hält fest, dass die Weitergabe-Konfiguration nur HTTPS kennt, die Signatur die Version binden
//! muss und der Installer ohne Rückfragen läuft.

/// `latest.json` am neuesten veröffentlichten Release. Entwürfe zählen bei GitHub nicht als „latest“: Ein Update
/// geht erst raus, wenn das Release veröffentlicht ist.
pub const FEED_URL: &str = "https://github.com/patrickbirkholz0000/knips/releases/latest/download/latest.json";
/// Erste Suche einige Minuten nach dem Start — nicht mitten in den Start hinein.
pub const FIRST_CHECK_SECS: u64 = 4 * 60;
/// Höchstens eine erfolgreiche Suche am Tag.
pub const CHECK_INTERVAL_SECS: i64 = 24 * 3600;
/// Nach einer gescheiterten Suche (kein Netz, GitHub antwortet nicht) erst so viel später wieder.
pub const RETRY_SECS: i64 = 6 * 3600;
/// So oft sieht der Hintergrund-Thread nach, ob eine Suche fällig ist (übersteht Ruhezustand und Uhrwechsel).
pub const WAKE_SECS: u64 = 3600;
/// Zeitlimit für den Feed (wenige hundert Bytes) und für den Installer.
pub const CHECK_TIMEOUT_SECS: u64 = 30;
pub const DOWNLOAD_TIMEOUT_SECS: u64 = 15 * 60;

/// Woher die Version kommt.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Feed {
    /// `FEED_URL` (aus tauri.conf.json).
    Release,
    /// Testkanal `KNIPS_UPDATE_FEED` (nur Entwickler-Builds).
    Test(String),
}

/// Darf diese Sitzung nach Updates fragen, und wo?
/// - Weitergabe-Build: ja, beim Release-Feed — außer in der CI (`CI`, `GITHUB_ACTIONS`) und der Test-Sandbox.
/// - Entwickler-Build (Feature `dev`, also auch alle Selbsttests): nie bei GitHub. Nur über den Testkanal
///   `KNIPS_UPDATE_FEED` (`https://…` oder `http://` auf diesen Rechner, siehe `test_feed_allowed`), dann auch in
///   Sandbox und CI — so prüft die CI die Aktualisierung von Ende zu Ende. Weitergabe-Builds lesen die Variable nie.
pub fn gate(sandbox: bool, dev_build: bool, env: impl Fn(&str) -> Option<String>) -> Option<Feed> {
    if dev_build {
        let url = env("KNIPS_UPDATE_FEED").map(|u| u.trim().to_string()).filter(|u| !u.is_empty())?;
        return test_feed_allowed(&url).then_some(Feed::Test(url));
    }
    let set = |name: &str| env(name).map(|v| !v.trim().is_empty()).unwrap_or(false);
    if sandbox || set("KNIPS_TEST_DIR") || set("CI") || set("GITHUB_ACTIONS") {
        return None;
    }
    Some(Feed::Release)
}

/// Testkanal: dieselbe Regel wie für `KNIPS_TELEMETRY_URL` — `https://` mit Rechnername oder `http://` auf diesen
/// Rechner (127.0.0.1, localhost, [::1]) für einen lokalen Test-Server.
pub fn test_feed_allowed(url: &str) -> bool {
    crate::telemetry::endpoint_override_allowed(url)
}

/// Braucht der Testkanal die HTTP-Ausnahme des Plugins? (Nur Entwickler-Builds setzen sie, nur dafür.)
pub fn test_feed_insecure(url: &str) -> bool {
    test_feed_allowed(url) && url.starts_with("http://")
}

/// Ist eine Suche fällig? `last_success`: letzte erfolgreiche Suche (gespeichert), `last_attempt`: letzter Versuch
/// in dieser Sitzung, auch ein gescheiterter. Uhr zurückgestellt → fällig.
pub fn due(now: i64, last_success: Option<i64>, last_attempt: Option<i64>) -> bool {
    let stale = match last_success {
        None => true,
        Some(t) => now - t >= CHECK_INTERVAL_SECS || now < t,
    };
    let resting = matches!(last_attempt, Some(t) if now >= t && now - t < RETRY_SECS);
    stale && !resting
}

/// Versionsnummer `X.Y.Z` (ohne Zusätze wie `-beta`; die verwendet Knips nicht).
pub fn parse_version(v: &str) -> Option<(u64, u64, u64)> {
    let mut parts = v.trim().trim_start_matches('v').split('.');
    let mut next = || parts.next().filter(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_digit())).and_then(|p| p.parse().ok());
    let version = (next()?, next()?, next()?);
    parts.next().is_none().then_some(version)
}

/// Ist `candidate` neuer als `current`? Unlesbare Nummern zählen nie als neuer.
pub fn is_newer(candidate: &str, current: &str) -> bool {
    matches!((parse_version(candidate), parse_version(current)), (Some(a), Some(b)) if a > b)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let pairs: Vec<(String, String)> = pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
        move |k: &str| pairs.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone())
    }

    #[test]
    fn gate_rules() {
        assert_eq!(gate(false, false, env(&[])), Some(Feed::Release));
        assert_eq!(gate(true, false, env(&[])), None, "Sandbox");
        assert_eq!(gate(false, false, env(&[("KNIPS_TEST_DIR", "C:\\t")])), None);
        assert_eq!(gate(false, false, env(&[("CI", "true")])), None);
        assert_eq!(gate(false, false, env(&[("GITHUB_ACTIONS", "true")])), None);
        assert_eq!(gate(false, false, env(&[("CI", " ")])), Some(Feed::Release));
        // Weitergabe-Builds lesen den Testkanal nie.
        assert_eq!(gate(false, false, env(&[("KNIPS_UPDATE_FEED", "http://127.0.0.1:9/latest.json")])), Some(Feed::Release));
        // Entwickler-Builds (und damit alle Selbsttests) nur über den Testkanal, nie bei GitHub.
        assert_eq!(gate(false, true, env(&[])), None, "Entwickler-Build ohne Testkanal");
        assert_eq!(gate(true, true, env(&[("CI", "1")])), None);
        let local = "http://127.0.0.1:8123/latest.json";
        assert_eq!(gate(false, true, env(&[("KNIPS_UPDATE_FEED", local)])), Some(Feed::Test(local.into())));
        // Testkanal gilt auch in Sandbox und CI (Ende-zu-Ende-Test).
        assert_eq!(gate(true, true, env(&[("KNIPS_UPDATE_FEED", local), ("CI", "true")])), Some(Feed::Test(local.into())));
        assert_eq!(
            gate(false, true, env(&[("KNIPS_UPDATE_FEED", "https://example.com/latest.json")])),
            Some(Feed::Test("https://example.com/latest.json".into()))
        );
        for bad in ["http://example.com/latest.json", "ftp://127.0.0.1/latest.json", "file:///C:/latest.json", "http://user@127.0.0.1/x", "  "] {
            assert_eq!(gate(false, true, env(&[("KNIPS_UPDATE_FEED", bad)])), None, "{bad}");
        }
        assert!(test_feed_insecure(local));
        assert!(!test_feed_insecure("https://example.com/latest.json"));
        assert!(!test_feed_insecure("http://example.com/latest.json"));
    }

    #[test]
    fn due_rules() {
        let day = CHECK_INTERVAL_SECS;
        let t = 1_800_000_000;
        assert!(due(t, None, None), "noch nie gesucht");
        assert!(!due(t + 3600, Some(t), None), "heute schon gesucht");
        assert!(!due(t + day - 1, Some(t), None));
        assert!(due(t + day, Some(t), None), "nach 24 h");
        assert!(due(t - 60, Some(t), None), "Uhr zurückgestellt");
        // Nach einem Fehler: Pause, dann wieder.
        assert!(!due(t + 60, None, Some(t)));
        assert!(!due(t + RETRY_SECS - 1, Some(t - 2 * day), Some(t)));
        assert!(due(t + RETRY_SECS, Some(t - 2 * day), Some(t)));
        assert!(due(t - 60, None, Some(t)), "Uhr vor den letzten Versuch zurückgestellt");
    }

    #[test]
    fn versions() {
        assert_eq!(parse_version("1.0.1"), Some((1, 0, 1)));
        assert_eq!(parse_version("v10.20.30"), Some((10, 20, 30)));
        for bad in ["", "1.0", "1.0.0.0", "1.0.x", "1..0", "1.0.0-beta", " "] {
            assert_eq!(parse_version(bad), None, "{bad}");
        }
        assert!(is_newer("1.0.2", "1.0.1"));
        assert!(is_newer("1.10.0", "1.9.9"));
        assert!(is_newer("2.0.0", "1.99.99"));
        assert!(!is_newer("1.0.1", "1.0.1"));
        assert!(!is_newer("1.0.0", "1.0.1"));
        assert!(!is_newer("kaputt", "1.0.1"));
        assert!(!is_newer("1.0.2", "kaputt"));
    }

    /// Base64 (Standard-Alphabet) — nur für den Test der Konfiguration.
    fn base64(text: &str) -> Vec<u8> {
        const ABC: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = vec![];
        let (mut acc, mut bits) = (0u32, 0);
        for c in text.bytes().filter(|&c| c != b'=') {
            let v = ABC.iter().position(|&a| a == c).expect("kein Base64") as u32;
            acc = (acc << 6) | v;
            bits += 6;
            if bits >= 8 {
                bits -= 8;
                out.push((acc >> bits) as u8);
            }
        }
        out
    }

    /// Weitergabe-Konfiguration des Updaters in tauri.conf.json: Feed nur über HTTPS (keine HTTP-Ausnahme), die
    /// Signatur muss die Version binden, Installer passiv (Fortschrittsbalken, keine Fragen), öffentlicher Schlüssel
    /// im Minisign-Format. Signiert wird erst der fertige (SignPath-)Installer in release.yml — `tauri build` erzeugt
    /// deshalb keine Updater-Dateien.
    #[test]
    fn release_config() {
        let conf: serde_json::Value = serde_json::from_str(include_str!("../../../src-tauri/tauri.conf.json")).unwrap();
        let updater = &conf["plugins"]["updater"];
        assert_eq!(updater["endpoints"], serde_json::json!([FEED_URL]));
        assert!(FEED_URL.starts_with("https://github.com/patrickbirkholz0000/knips/releases/latest/download/"));
        for key in ["dangerousInsecureTransportProtocol", "dangerousAcceptInvalidCerts", "dangerousAcceptInvalidHostnames", "allowDowngrades"] {
            assert!(updater.get(key).is_none(), "{key} gehört nicht in die Weitergabe-Konfiguration");
        }
        assert_eq!(updater["requireSignedVersion"], true);
        assert_eq!(updater["windows"]["installMode"], "passive");
        let pubkey = String::from_utf8(base64(updater["pubkey"].as_str().unwrap())).unwrap();
        let lines: Vec<&str> = pubkey.lines().collect();
        assert!(lines[0].starts_with("untrusted comment: minisign public key"), "{pubkey}");
        let key = base64(lines[1]);
        assert_eq!((key.len(), &key[..2]), (42, &b"Ed"[..]), "Ed25519-Schlüssel mit Kennung");
        assert_ne!(conf["bundle"]["createUpdaterArtifacts"], true);
    }
}
