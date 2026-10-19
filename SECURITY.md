# Sicherheit

## Lücke melden

Bitte melde Sicherheitslücken vertraulich über GitHub und **nicht** als öffentliches Issue:

1. Oben in diesem Repo den Reiter **Security** öffnen.
2. Auf **Report a vulnerability** klicken.
3. Beschreiben, was betroffen ist (macOS oder Windows, Version), wie es sich nachstellen lässt und was
   jemand damit anrichten könnte.

Die Meldung sehen nur du und die Betreuer des Repos. Nach der Korrektur kann daraus ein öffentlicher
Sicherheitshinweis werden; auf Wunsch wirst du dort genannt.

## Was als Sicherheitsproblem zählt

- Zensierte Inhalte, die in gespeicherten Dateien, in der Zwischenablage, beim Herausziehen, bei
  „Text kopieren“ oder in exportierten Videos und GIFs doch lesbar sind.
- Daten, die den Rechner verlassen, obwohl sie es laut [Datenschutz](README.md#datenschutz) nicht
  dürfen, oder Statistik, die trotz Ablehnung gesendet wird.
- Lücken im Statistik-Server unter `telemetry/`.
- Probleme mit Installer, Signatur oder Rechten der App.

Dass Verpixeln und Unschärfe grundsätzlich schwächer schützen als ein Balken, ist bekannt. Deshalb ist
der Balken der Standard.

## Unterstützte Versionen

Sicherheitskorrekturen gibt es für die jeweils neueste Version unter
[Releases](https://github.com/patrickbirkholz0000/knips/releases).

---

## Security (English)

Please report vulnerabilities privately through GitHub, not as a public issue: open the **Security**
tab of this repository and click **Report a vulnerability**. Include the affected platform and version,
steps to reproduce and the possible impact.

Especially relevant: censored content that is still readable in saved files, the clipboard, dragged
files, copied text or exported videos/GIFs; data leaving the computer contrary to the
[privacy section](README.md#privacy); issues in the statistics server in `telemetry/`; installer or
signing problems. Pixelation and blur being weaker than solid bars is known, which is why bars are the
default. Fixes are released for the latest version only.
