type PortlyMarkProps = {
  size?: number;
  className?: string;
};

export function PortlyMark({ size = 36, className = "" }: PortlyMarkProps) {
  return (
    <span
      className={`portly-mark ${className}`}
      style={{ width: size, height: size }}
      aria-hidden="true"
    >
      <svg viewBox="0 0 32 32" role="img">
        <path
          d="M5.5 18.3h7.2l-1.9 7.2L26.5 13.7h-7.2l1.9-7.2L5.5 18.3Z"
          fill="currentColor"
        />
      </svg>
    </span>
  );
}
