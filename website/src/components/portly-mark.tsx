type PortlyMarkProps = {
  size?: number;
  className?: string;
  /** Draws the glyph alone, without the app-icon tile. */
  bare?: boolean;
};

/**
 * The Portly mark: three inbound lanes converging into one supervised process.
 * Same geometry as the macOS app icon drawn by Tools/makeicon.swift.
 */
export function PortlyMark({
  size = 36,
  className = "",
  bare = false,
}: PortlyMarkProps) {
  const glyph = (
    <svg viewBox="0 0 24 24" role="img" aria-hidden="true">
      <g
        fill="none"
        stroke="currentColor"
        strokeWidth="2.3"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <path d="M2.9 5.8h3c3.6 0 3.3 6.2 6.9 6.2" />
        <path d="M2.9 12h9.9" />
        <path d="M2.9 18.2h3c3.6 0 3.3-6.2 6.9-6.2" />
      </g>
      <circle cx="18.1" cy="12" r="2.9" fill="currentColor" />
    </svg>
  );

  if (bare) {
    return (
      <span
        className={`portly-glyph ${className}`}
        style={{ width: size, height: size }}
      >
        {glyph}
      </span>
    );
  }

  return (
    <span
      className={`portly-mark ${className}`}
      style={{ width: size, height: size }}
      aria-hidden="true"
    >
      {glyph}
    </span>
  );
}
