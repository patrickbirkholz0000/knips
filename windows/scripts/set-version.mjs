// Setzt die Version für einen Release-Build in package.json, src-tauri/tauri.conf.json und Cargo.toml
// ([workspace.package]). Nur im Arbeitsverzeichnis der CI, wird nicht eingecheckt.
//   node scripts/set-version.mjs 1.2.0      (aus windows/)
import fs from "node:fs";

const version = process.argv[2] ?? "";
if (!/^\d+\.\d+\.\d+$/.test(version)) {
  console.error(`Version '${version}' hat nicht die Form X.Y.Z.`);
  process.exit(1);
}

for (const file of ["package.json", "src-tauri/tauri.conf.json"]) {
  const json = JSON.parse(fs.readFileSync(file, "utf8"));
  json.version = version;
  fs.writeFileSync(file, JSON.stringify(json, null, 2) + "\n");
}

const cargo = fs.readFileSync("Cargo.toml", "utf8");
const re = /(\[workspace\.package\][^[]*?\nversion\s*=\s*")[^"]*(")/;
if (!re.test(cargo)) {
  console.error("Cargo.toml: version in [workspace.package] nicht gefunden");
  process.exit(1);
}
fs.writeFileSync("Cargo.toml", cargo.replace(re, (_, head, tail) => head + version + tail));
console.log(`Version ${version} gesetzt (package.json, tauri.conf.json, Cargo.toml).`);
