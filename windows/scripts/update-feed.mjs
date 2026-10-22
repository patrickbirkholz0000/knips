// Feed für die automatische Aktualisierung (latest.json) erzeugen und prüfen — ohne Abhängigkeiten, nur Node.
// Prüft die Updater-Signatur genau wie tauri-plugin-updater (Minisign: Ed25519 über BLAKE2b-512 der Datei, dazu die
// globale Signatur über den vertrauenswürdigen Kommentar, der die Version nennen muss).
//
//   node scripts/update-feed.mjs --installer <setup.exe> --version X.Y.Z --url <download-adresse> [--notes <text>]
//        [--pubkey <base64> | --config src-tauri/tauri.conf.json] --out latest.json
//     liest <setup.exe>.sig (von `tauri signer sign --app-version X.Y.Z`), prüft sie gegen den öffentlichen Schlüssel
//     und schreibt latest.json: version, notes, pub_date, platforms.windows-x86_64.{signature,url}.
//   node scripts/update-feed.mjs --check latest.json --installer <setup.exe> [--pubkey … | --config …] [--allow-http]
//     prüft einen fertigen Feed gegen die Datei: Form, Version, Adresse (HTTPS, Dateiname), Signatur.
//
// Ohne --pubkey gilt der Schlüssel aus src-tauri/tauri.conf.json (plugins.updater.pubkey). Exit 1 mit Grund.
import { createHash, createPublicKey, verify } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { basename } from "node:path";

const args = process.argv.slice(2);
const opt = (name) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
};
const has = (name) => args.includes(`--${name}`);

function fail(message) {
  console.error(`FEHLER: ${message}`);
  process.exit(1);
}

const SEMVER = /^\d+\.\d+\.\d+$/;

/** Base64-Text → Zeilen des Minisign-Formats. */
function minisignLines(b64, what) {
  const text = Buffer.from(b64.trim(), "base64").toString("utf8");
  const lines = text.split(/\r?\n/);
  if (!lines[0]?.startsWith("untrusted comment:")) fail(`${what}: kein Minisign-Format`);
  return lines;
}

function publicKey(b64) {
  const raw = Buffer.from(minisignLines(b64, "Öffentlicher Schlüssel")[1] ?? "", "base64");
  if (raw.length !== 42 || raw.subarray(0, 2).toString() !== "Ed") fail("Öffentlicher Schlüssel: kein Ed25519-Schlüssel");
  // Rohschlüssel (32 Bytes) als SubjectPublicKeyInfo für Node.
  const der = Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), raw.subarray(10)]);
  return { keyId: raw.subarray(2, 10), key: createPublicKey({ key: der, format: "der", type: "spki" }) };
}

/** Prüft `signatureB64` (Inhalt der .sig-Datei) über `data`. Liefert die Felder des vertrauenswürdigen Kommentars. */
function verifySignature(data, signatureB64, pub) {
  const lines = minisignLines(signatureB64, "Signatur");
  const sigBox = Buffer.from(lines[1] ?? "", "base64");
  const trusted = lines[2] ?? "";
  const global = Buffer.from(lines[3] ?? "", "base64");
  if (sigBox.length !== 74 || !trusted.startsWith("trusted comment: ") || global.length !== 64) fail("Signatur unvollständig");
  const alg = sigBox.subarray(0, 2).toString();
  if (!sigBox.subarray(2, 10).equals(pub.keyId)) fail("Signatur stammt von einem anderen Schlüssel (Schlüssel-ID passt nicht)");
  // „ED“: Ed25519 über BLAKE2b-512 der Datei (tauri signer), „Ed“: über die Datei selbst (älteres Minisign).
  const message = alg === "ED" ? createHash("blake2b512").update(data).digest() : alg === "Ed" ? data : fail(`Signaturverfahren ${alg} unbekannt`);
  if (!verify(null, message, pub.key, sigBox.subarray(10))) fail("Signatur passt nicht zur Datei");
  const comment = trusted.slice("trusted comment: ".length);
  if (!verify(null, Buffer.concat([sigBox.subarray(10), Buffer.from(comment, "utf8")]), pub.key, global)) fail("Globale Signatur (vertrauenswürdiger Kommentar) ungültig");
  return Object.fromEntries(comment.split("\t").map((f) => [f.slice(0, f.indexOf(":")), f.slice(f.indexOf(":") + 1)]));
}

function pubkeyFromArgs() {
  if (opt("pubkey")) return publicKey(opt("pubkey"));
  const conf = JSON.parse(readFileSync(opt("config") ?? "src-tauri/tauri.conf.json", "utf8"));
  const b64 = conf?.plugins?.updater?.pubkey;
  if (!b64) fail("tauri.conf.json: plugins.updater.pubkey fehlt");
  return publicKey(b64);
}

/** Prüft einen Feed gegen die Installer-Datei. */
function check(feed, installer, pub, allowHttp) {
  if (!SEMVER.test(feed.version ?? "")) fail(`latest.json: Version „${feed.version}“ hat nicht die Form X.Y.Z`);
  if (Number.isNaN(Date.parse(feed.pub_date ?? ""))) fail("latest.json: pub_date fehlt oder ist kein Datum (RFC 3339)");
  const entry = feed.platforms?.["windows-x86_64"];
  if (!entry?.url || !entry?.signature) fail("latest.json: platforms.windows-x86_64 mit url und signature fehlt");
  const url = new URL(entry.url);
  if (url.protocol !== "https:" && !(allowHttp && url.protocol === "http:" && ["127.0.0.1", "localhost"].includes(url.hostname))) {
    fail(`latest.json: Download-Adresse nicht über HTTPS: ${entry.url}`);
  }
  if (decodeURIComponent(basename(url.pathname)) !== basename(installer)) fail(`latest.json: Adresse zeigt auf ${basename(url.pathname)}, geprüft wird ${basename(installer)}`);
  const fields = verifySignature(readFileSync(installer), entry.signature, pub);
  if (fields.version !== feed.version) fail(`Signatur gilt für Version „${fields.version ?? "(keine)"}“, latest.json nennt ${feed.version}`);
  return fields;
}

const installer = opt("installer") ?? fail("--installer fehlt");
const pub = pubkeyFromArgs();

if (opt("check")) {
  const feed = JSON.parse(readFileSync(opt("check"), "utf8"));
  const fields = check(feed, installer, pub, has("allow-http"));
  console.log(`latest.json gültig: Version ${feed.version}, ${basename(installer)} signiert (${fields.file ?? "?"}, Zeitstempel ${fields.timestamp ?? "?"})`);
} else {
  const version = opt("version") ?? fail("--version fehlt");
  if (!SEMVER.test(version)) fail(`Version „${version}“ hat nicht die Form X.Y.Z`);
  const url = opt("url") ?? fail("--url fehlt");
  const out = opt("out") ?? fail("--out fehlt");
  const signature = readFileSync(`${installer}.sig`, "utf8").trim();
  const feed = {
    version,
    notes: opt("notes") ?? `Knips ${version}`,
    pub_date: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    platforms: { "windows-x86_64": { signature, url } },
  };
  check(feed, installer, pub, has("allow-http"));
  writeFileSync(out, JSON.stringify(feed, null, 2) + "\n");
  // Zur Sicherheit noch einmal so, wie es auf der Platte liegt.
  check(JSON.parse(readFileSync(out, "utf8")), installer, pub, has("allow-http"));
  console.log(`latest.json geschrieben und geprüft: ${out} (Version ${version}, ${url})`);
}
