interface MarketRouteLogoProps {
  compact?: boolean;
  className?: string;
}

export function MarketRouteLogo({ compact = false, className = "" }: MarketRouteLogoProps) {
  return (
    <div className={["mr-logo", compact ? "mr-logo--compact" : "", className].filter(Boolean).join(" ")}>
      <svg className="mr-logo__mark" viewBox="0 0 32 32" role="img" aria-label="MarketRoute">
        <path d="M5 23.5V8.5h5.25l5.75 8.25L21.75 8.5H27v15" fill="none" stroke="currentColor" strokeWidth="2.15" strokeLinecap="round" strokeLinejoin="round" />
        <circle cx="5" cy="23.5" r="2.1" fill="currentColor" />
        <circle cx="16" cy="16.75" r="2.1" fill="currentColor" />
        <circle cx="27" cy="23.5" r="2.1" fill="currentColor" />
      </svg>
      {!compact && (
        <span className="mr-logo__wordmark">
          Market<span>Route</span>
        </span>
      )}
    </div>
  );
}
