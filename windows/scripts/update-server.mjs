// Lokaler Feed-Server für den Ende-zu-Ende-Test der Aktualisierung (scripts/update-test.ps1): liefert Dateien aus
// einem Ordner über http://127.0.0.1:<port>/ und schreibt jede Anfrage als Zeile ins Protokoll.
//   node scripts/update-server.mjs <ordner> <portdatei> <protokoll>
// Der Port (frei gewählt) steht danach in <portdatei>. Nur GET, nur Dateien unterhalb von <ordner>.
import { createServer } from "node:http";
import { appendFileSync, createReadStream, statSync, writeFileSync } from "node:fs";
import { join, normalize, sep } from "node:path";

const [root, portFile, log] = process.argv.slice(2);
if (!root || !portFile || !log) {
  console.error("Aufruf: node scripts/update-server.mjs <ordner> <portdatei> <protokoll>");
  process.exit(2);
}
const base = normalize(root + sep);

const server = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname);
  const file = normalize(join(base, path));
  let status = 404;
  try {
    if (req.method === "GET" && file.startsWith(base) && statSync(file).isFile()) {
      status = 200;
      res.writeHead(200, { "Content-Type": file.endsWith(".json") ? "application/json" : "application/octet-stream", "Content-Length": statSync(file).size });
      createReadStream(file).pipe(res);
    }
  } catch {}
  if (status !== 200) {
    res.writeHead(404, { "Content-Type": "text/plain" });
    res.end("fehlt");
  }
  appendFileSync(log, `${new Date().toISOString()} ${req.method} ${path} ${status}\n`);
});
server.listen(0, "127.0.0.1", () => writeFileSync(portFile, String(server.address().port)));
