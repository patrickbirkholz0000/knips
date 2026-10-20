-- Knips-Telemetrie (Cloudflare D1). Je Installation und UTC-Tag eine Zeile, die Zähler daneben.
-- Keine IP-Adresse, kein User-Agent, keine install_id — nur deren gesalzener Hash.

CREATE TABLE IF NOT EXISTS daily (
  day TEXT NOT NULL,              -- JJJJ-MM-TT, UTC
  install_hash TEXT NOT NULL,     -- sha256(install_id + SALT), erste 32 Hex-Zeichen
  platform TEXT NOT NULL,         -- macos | windows
  channel TEXT NOT NULL,          -- release | dev
  app_version TEXT,
  build TEXT,
  os_version TEXT,
  arch TEXT,                      -- arm64 | x86_64
  lang TEXT,                      -- zwei Buchstaben
  country TEXT,                   -- zwei Buchstaben aus request.cf.country
  pings INTEGER NOT NULL DEFAULT 1,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (day, install_hash)
);
CREATE INDEX IF NOT EXISTS daily_channel_day ON daily (channel, day);
CREATE INDEX IF NOT EXISTS daily_install_day ON daily (install_hash, day);

CREATE TABLE IF NOT EXISTS daily_events (
  day TEXT NOT NULL,
  install_hash TEXT NOT NULL,
  name TEXT NOT NULL,             -- nur Namen aus der Liste in src/index.js
  count INTEGER NOT NULL,
  PRIMARY KEY (day, install_hash, name)
);
CREATE INDEX IF NOT EXISTS daily_events_day ON daily_events (day);

-- Neue Installationen je UTC-Tag, nur als Zahl: Obergrenze gegen massenhaft erfundene IDs (src/index.js).
CREATE TABLE IF NOT EXISTS daily_new (
  day TEXT PRIMARY KEY,           -- JJJJ-MM-TT, UTC
  installs INTEGER NOT NULL
);
