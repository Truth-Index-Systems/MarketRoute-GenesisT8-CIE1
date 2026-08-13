interface ProvenanceItem {
  label: string;
  value: string;
}

interface ProvenanceTrailProps {
  items: ProvenanceItem[];
}

export function ProvenanceTrail({ items }: ProvenanceTrailProps) {
  return (
    <dl className="mr-provenance-trail">
      {items.map((item) => (
        <div key={item.label}>
          <dt>{item.label}</dt>
          <dd>{item.value}</dd>
        </div>
      ))}
    </dl>
  );
}
