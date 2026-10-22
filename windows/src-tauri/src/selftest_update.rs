//! Selbsttest `update` (Feature `dev`): automatische Aktualisierung gegen einen lokalen Feed-Server auf 127.0.0.1
//! im Testkanal (`KNIPS_UPDATE_FEED`, gesetzt vor dem Start der App). Installiert nichts — das prüft der
//! Ende-zu-Ende-Test `scripts/update-test.ps1` mit zwei echten Installern.
//!
//! Geprüft: Regeln (nie ohne Testkanal, Weitergabe nur HTTPS), gleiche/ältere Version → nichts, veränderte Datei,
//! fremder Schlüssel und Versionsnummer, die nicht zur Signatur passt → verworfen, richtige Signatur → geladen und
//! bereit, kein zweiter Download, automatische Suche höchstens einmal am Tag und nie mit ausgeschalteter
//! Einstellung, „Jetzt suchen“ über den Hintergrund-Thread und die Oberfläche, Installieren gesperrt während einer
//! Aufnahme oder mit offenen Editoren (Knöpfe in Menü und Einstellungen zeigen den Grund), Zwischenspeicher nach
//! einem Neustart (verändert → verworfen). Bilder: `einstellungen-about-update[-dunkel].png`, `menu-update.png`.
//!
//! Signaturen und öffentlicher Schlüssel unten stammen von zwei Wegwerf-Schlüsseln (A, B) ohne Passwort, erzeugt mit
//! `tauri signer generate`, signiert mit `tauri signer sign --app-version 99.0.0` über `test_package()`. Sie gelten
//! nur für dieses Testpaket; die App nimmt sie nur hier über `TestHooks::pubkey`.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use knips_core::settings::Appearance;
use knips_core::update::{self as upd, Feed};
use parking_lot::Mutex;
use tauri::{AppHandle, Manager};

use crate::selftest::{probe, shoot};
use crate::update::{Blocker, Outcome, Updates};

/// Öffentlicher Schlüssel A (Wegwerf, nur Selbsttest).
const TEST_PUBKEY: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDZCOEZDN0IzQzlBM0VGRUUKUldUdTc2UEpzOGVQYTBRNEROODVSOFdaNmpkT01TZUhnOGsrTHZaNDhVMTFQRHErYUR4R0poQUYK";
/// `test_package()`, signiert mit A für Version 99.0.0.
const SIG_A: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVUdTc2UEpzOGVQYTBIaWFTdTQ0SDJET3Y1WVZUUmFuSE13dUV2UCszUC9iUEJFSEszVXdWZ0xsMVhPcEZpc0x0Z2ZNOXVMRXFEY0h5cStmcWdHTHVTc09adkE2Q05iSlFzPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzkyNjIwMzIxCWZpbGU6cGFrZXQtYS5leGUJdmVyc2lvbjo5OS4wLjAKbzVLeVlIQ3FaS1YrOE5Lc1VSYm0vZzd5VnlmS1RpQzUyaDVmQSsvd1RFVlltV0hUTDI4Rnp1RGNBa1dwaHNINWtpc3d2V1crQVFlR29nMFFjVlI5QkE9PQo=";
/// Dasselbe Paket, signiert mit dem fremden Schlüssel B.
const SIG_B: &str = "dW50cnVzdGVkIGNvbW1lbnQ6IHNpZ25hdHVyZSBmcm9tIHRhdXJpIHNlY3JldCBrZXkKUlVSamsvdHNJdjA2dDRPTzBvaHJpQzlxaERaVDNyREdPMVh6OHhaNUxINkI4MURpRjF6OG5xd1lsdU9RRGovZFlQTVF4MXo4dGZweWFwdVNRRmlPTkFxZXVBWnFqcThFaUFVPQp0cnVzdGVkIGNvbW1lbnQ6IHRpbWVzdGFtcDoxNzkyNjIwMzIyCWZpbGU6cGFrZXQtYi5leGUJdmVyc2lvbjo5OS4wLjAKVEZCWDRzU3dsa1o4dFlnYkZhNFg1cmV3RWVrbC9IWC8vZmFRWGJYS29kb1hSaG9xTlk3ZXRZeS80U0FiaWVBN2wxOWJlNVdtaDFXWGlKYXJYanNrQ0E9PQo=";

/// Testpaket: beginnt wie eine EXE („MZ“), danach fester Text, 4096 Bytes. Wird nie ausgeführt.
fn test_package() -> Vec<u8> {
    let mut data = b"MZ".to_vec();
    while data.len() < 4096 {
        data.extend_from_slice(b"Knips Selbsttest Aktualisierung. ");
    }
    data.truncate(4096);
    data
}

/// Lokaler Server: `/latest.json` und `/paket.exe` aus dem Speicher, zählt Anfragen je Pfad.
struct FeedServer {
    port: u16,
    feed: Mutex<String>,
    package: Mutex<Vec<u8>>,
    hits: Mutex<BTreeMap<String, usize>>,
}

impl FeedServer {
    fn start() -> Result<Arc<Self>> {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
        let server = Arc::new(Self { port: listener.local_addr()?.port(), feed: Mutex::new("{}".into()), package: Mutex::new(test_package()), hits: Mutex::new(BTreeMap::new()) });
        let this = server.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                let mut reader = BufReader::new(&stream);
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() {
                    continue;
                }
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).unwrap_or(0) == 0 || header.trim().is_empty() {
                        break;
                    }
                }
                let path = line.split_whitespace().nth(1).unwrap_or("").to_string();
                *this.hits.lock().entry(path.clone()).or_default() += 1;
                let (status, kind, body) = match path.as_str() {
                    "/latest.json" => ("200 OK", "application/json", this.feed.lock().clone().into_bytes()),
                    "/paket.exe" => ("200 OK", "application/octet-stream", this.package.lock().clone()),
                    _ => ("404 Not Found", "text/plain", b"fehlt".to_vec()),
                };
                let mut w = &stream;
                let _ = write!(w, "HTTP/1.1 {status}\r\nContent-Type: {kind}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
                let _ = w.write_all(&body);
                let _ = w.flush();
            }
        });
        Ok(server)
    }

    fn url(&self, path: &str) -> String {
        format!("http://127.0.0.1:{}{path}", self.port)
    }

    /// Feed mit Version, Signatur und Download-Adresse (Format wie `scripts/update-feed.mjs`).
    fn set_feed(&self, version: &str, signature: &str) {
        let feed = serde_json::json!({
            "version": version,
            "notes": "Selbsttest",
            "pub_date": "2026-10-21T12:00:00Z",
            "platforms": { "windows-x86_64": { "signature": signature, "url": self.url("/paket.exe") } },
        });
        *self.feed.lock() = feed.to_string();
    }

    fn hits(&self, path: &str) -> usize {
        self.hits.lock().get(path).copied().unwrap_or(0)
    }
}

static SERVER: OnceLock<Arc<FeedServer>> = OnceLock::new();

/// Vor dem Start der App (`selftest::run`): Server starten, Testkanal setzen. Die automatische Suche wartet eine
/// Stunde — der Test steuert jede Suche selbst.
pub fn prepare() -> Result<()> {
    let server = FeedServer::start()?;
    std::env::set_var("KNIPS_UPDATE_FEED", server.url("/latest.json"));
    std::env::set_var("KNIPS_UPDATE_DELAY", "3600");
    let _ = SERVER.set(server);
    Ok(())
}

fn until(secs: u64, ok: impl Fn() -> bool) -> bool {
    let deadline = Instant::now() + Duration::from_secs(secs);
    while Instant::now() < deadline {
        if ok() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    ok()
}

pub fn update(app: &AppHandle, out: &Path) -> Result<()> {
    let k = crate::app::knips();
    let server = SERVER.get().context("Feed-Server fehlt (prepare)")?;
    let u = &k.updates;
    let mut failures: Vec<String> = vec![];
    let mut expect = |ok: bool, what: &str| {
        if ok {
            println!("   ✓ {what}");
        } else {
            println!("   FALSCH {what}");
            failures.push(what.to_string());
        }
    };
    let current = app.package_info().version.to_string();
    println!("Installierte Version {current}, Feed {}", server.url("/latest.json"));

    // 1. Regeln: ohne Testkanal sucht diese Sitzung nie (Selbsttest, Sandbox, CI, Entwickler-Build), mit Testkanal
    //    schon; die HTTP-Ausnahme gilt nur hier (Weitergabe-Konfiguration: Kern-Test `release_config`).
    let env = |pairs: &'static [(&'static str, &'static str)]| move |k: &str| pairs.iter().find(|(n, _)| *n == k).map(|(_, v)| v.to_string());
    expect(upd::gate(true, true, env(&[])).is_none(), "Selbsttest/Sandbox ohne Testkanal: keine Suche");
    expect(upd::gate(false, true, env(&[("CI", "true")])).is_none(), "Entwickler-Build in der CI ohne Testkanal: keine Suche");
    expect(upd::gate(false, false, env(&[("CI", "true")])).is_none(), "Weitergabe-Build in der CI: keine Suche");
    expect(upd::gate(false, false, env(&[])) == Some(Feed::Release), "Weitergabe-Build beim Nutzer: GitHub-Release");
    let off = Updates::new(k.settings.clone(), None);
    expect(off.tick(chrono::Utc::now().timestamp()) == Outcome::Off && off.check_now() == Outcome::Off && !off.status().available, "Sitzung ohne Feed: nie eine Suche");
    expect(u.test_channel() && u.status().available, "Testkanal aktiv");
    let insecure = app.config().plugins.0.get("updater").and_then(|c| c.get("dangerousInsecureTransportProtocol")).cloned();
    expect(insecure == Some(serde_json::Value::Bool(true)), "HTTP-Ausnahme nur im Testkanal des Entwickler-Builds gesetzt");
    expect(server.hits("/latest.json") == 0, "keine Suche vor dem Test (erste automatische nach einer Stunde)");
    u.test.lock().pubkey = Some(TEST_PUBKEY.into());

    // 2. Gleiche und ältere Version → nichts, kein Download.
    for version in [current.as_str(), "0.0.1"] {
        server.set_feed(version, SIG_A);
        let r = u.check_now();
        expect(r == Outcome::Current && server.hits("/paket.exe") == 0 && !u.is_ready(), &format!("Feed {version}: nichts zu tun ({r:?})"));
    }
    expect(u.status().result == Some("current") && k.settings.get().update_last_check.is_some(), "aktuell, Zeitpunkt der Suche gespeichert");

    // 3. Verworfen: veränderte Datei, fremder Schlüssel, Versionsnummer passt nicht zur Signatur.
    let mut tampered = test_package();
    tampered[2000] ^= 0x01;
    *server.package.lock() = tampered;
    server.set_feed("99.0.0", SIG_A);
    let r = u.check_now();
    let status = u.status();
    expect(matches!(r, Outcome::Failed(_)) && !u.is_ready() && server.hits("/paket.exe") == 1, &format!("veränderte Datei verworfen ({r:?})"));
    expect(status.result == Some("error") && status.error.as_deref().is_some_and(|e| e.contains("Signatur")), &format!("Grund für Menschen: {:?}", status.error));
    *server.package.lock() = test_package();
    server.set_feed("99.0.0", SIG_B);
    let r = u.check_now();
    expect(matches!(r, Outcome::Failed(_)) && !u.is_ready(), &format!("fremder Schlüssel verworfen ({r:?})"));
    server.set_feed("99.0.1", SIG_A);
    let r = u.check_now();
    expect(matches!(&r, Outcome::Failed(e) if e.contains("99.0.0")) && !u.is_ready(), &format!("Feed nennt 99.0.1, signiert ist 99.0.0: verworfen ({r:?})"));

    // 4. Richtig signiert → geladen, geprüft, bereit, im Zwischenspeicher.
    server.set_feed("99.0.0", SIG_A);
    let downloads = server.hits("/paket.exe");
    let before = chrono::Utc::now().timestamp();
    let r = u.check_now();
    let status = u.status();
    expect(r == Outcome::Ready("99.0.0".into()) && u.is_ready() && server.hits("/paket.exe") == downloads + 1, &format!("99.0.0 geladen ({r:?})"));
    expect(status.phase == "ready" && status.version.as_deref() == Some("99.0.0") && status.error.is_none(), &format!("Status {status:?}"));
    expect(k.settings.get().update_last_check.is_some_and(|t| t >= before), "Zeitpunkt der Suche gespeichert");
    let cache = crate::paths::data_dir().join("update");
    expect(std::fs::read(cache.join("Knips-setup.exe")).ok() == Some(test_package()), "Installer im Zwischenspeicher");
    expect(k.bootstrap().update.version.as_deref() == Some("99.0.0"), "Bootstrap meldet die geladene Version");

    // 5. Nochmal suchen: bleibt bereit, kein zweiter Download.
    let r = u.check_now();
    expect(r == Outcome::Ready("99.0.0".into()) && server.hits("/paket.exe") == downloads + 1, "zweite Suche lädt nicht erneut");

    // 6. Automatisch: höchstens einmal am Tag, nie mit ausgeschalteter Einstellung.
    let now = chrono::Utc::now().timestamp();
    let feeds = server.hits("/latest.json");
    expect(u.tick(now + 3600) == Outcome::NotDue && server.hits("/latest.json") == feeds, "heute schon gesucht: keine automatische Suche");
    let r = u.tick(now + 25 * 3600);
    expect(r == Outcome::Ready("99.0.0".into()) && server.hits("/latest.json") == feeds + 1, &format!("nach 24 h automatisch ({r:?})"));
    k.settings.update(|s| s.auto_update = false);
    expect(u.tick(now + 60 * 3600) == Outcome::AutoOff && server.hits("/latest.json") == feeds + 1, "Einstellung aus: keine automatische Suche");
    let feeds = server.hits("/latest.json");
    u.request_check();
    expect(until(10, || server.hits("/latest.json") == feeds + 1), "„Jetzt suchen“ geht auch mit ausgeschalteter Einstellung (Hintergrund-Thread)");
    k.settings.update(|s| s.auto_update = true);

    // 7. Installieren gesperrt: Aufnahme, Schreibvorgänge, offene Editoren (nur beim Neustart per Knopf).
    for blocker in [Blocker::Recording, Blocker::Scroll, Blocker::Writing] {
        u.test.lock().blocker = Some(blocker);
        expect(u.install(false) == Err(blocker.text().into()) && u.is_ready(), &format!("beim Beenden gesperrt: {blocker:?}"));
    }
    u.test.lock().blocker = None;
    expect(u.blocker(true).is_none() && u.blocker(false).is_none(), "ohne Aufnahme und Editoren nichts im Weg");

    // 8. Oberfläche: Einstellungen → Über Knips und Menü zeigen das Update; die Knöpfe melden den Grund, warum es
    //    gerade nicht geht, und „Jetzt suchen“ sucht wirklich.
    let appearance = k.settings.get().appearance;
    k.settings.update(|s| s.appearance = Appearance::Light);
    k.broadcast_bootstrap();
    crate::commands::show_settings(app, Some("about".into()));
    std::thread::sleep(Duration::from_millis(1200));
    let settings_w = app.get_webview_window("settings").context("Einstellungen fehlen")?;
    let _ = settings_w.eval("document.querySelector('.st-update')?.scrollIntoView({ block: 'center' })");
    std::thread::sleep(Duration::from_millis(400));
    if let Err(err) = shoot(app, "settings", out, "einstellungen-about-update.png") {
        expect(false, &format!("Bild Einstellungen: {err:#}"));
    }
    let shown = probe(&settings_w, "document.querySelector('.st-update')?.textContent ?? ''", Duration::from_secs(3)).unwrap_or_default();
    expect(shown.contains("99.0.0 ist bereit") && shown.contains("Neu starten und aktualisieren"), &format!("Einstellungen: „{shown}“"));
    u.test.lock().blocker = Some(Blocker::Editors);
    let answer = probe(
        &settings_w,
        "new Promise(r => { document.querySelector('[data-act=update-install]').click(); setTimeout(() => r(document.querySelector('.st-update .st-fail')?.textContent ?? 'nichts'), 800); })",
        Duration::from_secs(5),
    )
    .unwrap_or_default();
    expect(answer.contains(Blocker::Editors.text()), &format!("Knopf in den Einstellungen nennt den Grund: „{answer}“"));
    let feeds = server.hits("/latest.json");
    let _ = probe(&settings_w, "(document.querySelector('[data-act=update-check]').click(), 'ok')", Duration::from_secs(3));
    expect(until(10, || server.hits("/latest.json") == feeds + 1), "Knopf „Jetzt nach Updates suchen“ sucht");
    std::thread::sleep(Duration::from_millis(500));
    k.settings.update(|s| s.appearance = Appearance::Dark);
    k.broadcast_bootstrap();
    std::thread::sleep(Duration::from_millis(800));
    let _ = settings_w.eval("document.querySelector('.st-update')?.scrollIntoView({ block: 'center' })");
    std::thread::sleep(Duration::from_millis(400));
    if let Err(err) = shoot(app, "settings", out, "einstellungen-about-update-dunkel.png") {
        expect(false, &format!("Bild Einstellungen dunkel: {err:#}"));
    }
    let _ = settings_w.hide();
    k.settings.update(|s| s.appearance = appearance);
    k.broadcast_bootstrap();

    let m = knips_platform::monitors::primary();
    crate::menu::show(app, Some((m.work.right() - 200, m.work.bottom() + 10)));
    std::thread::sleep(Duration::from_millis(1200));
    if let Err(err) = shoot(app, crate::menu::LABEL, out, "menu-update.png") {
        expect(false, &format!("Bild Menü: {err:#}"));
    }
    let menu_w = app.get_webview_window(crate::menu::LABEL).context("Menü fehlt")?;
    let answer = probe(
        &menu_w,
        "new Promise(r => { document.querySelector('[data-act=update-install]').click(); setTimeout(() => r(document.querySelector('.mp-update')?.textContent ?? 'nichts'), 800); })",
        Duration::from_secs(5),
    )
    .unwrap_or_default();
    expect(answer.contains("99.0.0 ist bereit") && answer.contains(Blocker::Editors.text()), &format!("Menü: Hinweis und Grund „{answer}“"));
    crate::menu::close(app);
    u.test.lock().blocker = None;

    // 9. Zwischenspeicher nach einem Neustart: bereit ohne Netz; verändert → verworfen.
    let feeds = (server.hits("/latest.json"), server.hits("/paket.exe"));
    let fresh = Updates::new(k.settings.clone(), Some(Feed::Test(server.url("/latest.json"))));
    fresh.test.lock().pubkey = Some(TEST_PUBKEY.into());
    fresh.restore_cached();
    expect(fresh.status().version.as_deref() == Some("99.0.0") && (server.hits("/latest.json"), server.hits("/paket.exe")) == feeds, "nach Neustart bereit aus dem Zwischenspeicher, ohne Netz");
    let mut bytes = std::fs::read(cache.join("Knips-setup.exe"))?;
    bytes[100] ^= 0x01;
    std::fs::write(cache.join("Knips-setup.exe"), bytes)?;
    let fresh = Updates::new(k.settings.clone(), Some(Feed::Test(server.url("/latest.json"))));
    fresh.test.lock().pubkey = Some(TEST_PUBKEY.into());
    fresh.restore_cached();
    expect(!fresh.is_ready() && !cache.exists(), "veränderter Zwischenspeicher verworfen und gelöscht");

    println!("   Anfragen: {:?}", server.hits.lock());
    if !failures.is_empty() {
        bail!(failures.join("; "));
    }
    Ok(())
}
