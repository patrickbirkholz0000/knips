// Zeichen und Wortmarke von Knips (docs/design.md, „Logo und Wortmarke“) — gleiche Geometrie wie
// Sources/Knips/UI/BrandMark.swift: vier Auswahl-Ecken (die Auswahl) und ein Balken darin (die Zensur),
// Einheiten 0…100. Während eines Videos wird der Balken zum roten Punkt.
import "./brand.css";

const LO = 22;
const HI = 78;
const ARM = 17;

const CORNERS =
  `M${LO} ${LO + ARM}V${LO}H${LO + ARM}` +
  `M${HI - ARM} ${LO}H${HI}V${LO + ARM}` +
  `M${HI} ${HI - ARM}V${HI}H${HI - ARM}` +
  `M${LO + ARM} ${HI}H${LO}V${HI - ARM}`;

export function BrandMark({
  size = 22,
  recording = false,
  ink = "var(--k-side-ink)",
  accent = "var(--k-dark-accent)",
}: {
  size?: number;
  recording?: boolean;
  ink?: string;
  accent?: string;
}) {
  return (
    <svg className="k-mark" width={size} height={size} viewBox="0 0 100 100" aria-hidden="true">
      <path d={CORNERS} fill="none" stroke={ink} strokeWidth={9} strokeLinecap="round" strokeLinejoin="round" />
      {recording ? (
        <circle cx={50} cy={50} r={9} fill="var(--k-dark-record)" />
      ) : (
        <rect x={33} y={45.5} width={34} height={9} rx={4.5} fill={accent} />
      )}
    </svg>
  );
}

/** „knips“ in Kleinbuchstaben, Outfit halbfett; der i-Punkt ist die Aufnahmelampe (Königsblau, beim Video rot pulsierend). */
export function Wordmark({ size = 20, recording = false }: { size?: number; recording?: boolean }) {
  return (
    <span className="k-wordmark" style={{ fontSize: size }} aria-label="Knips">
      kn
      <span className="k-wordmark__i">
        ı<i className={recording ? "k-wordmark__lamp is-recording" : "k-wordmark__lamp"} />
      </span>
      ps
    </span>
  );
}

/** Zeichen + Wortmarke nebeneinander (Kopf der Seitenleiste, Menü-Panel). */
export function Brand({ size = 20, recording = false }: { size?: number; recording?: boolean }) {
  return (
    <span className="k-brand">
      <BrandMark size={Math.round(size * 1.2)} recording={recording} />
      <Wordmark size={size} recording={recording} />
    </span>
  );
}
