export interface RouteNodeView {
  label: string;
  meta?: string;
  kind: "company" | "unit" | "person" | "channel";
}

interface RoutePathProps {
  nodes: RouteNodeView[];
  caption?: string;
}

export function RoutePath({ nodes, caption }: RoutePathProps) {
  return (
    <div className="mr-route-path">
      <div className="mr-route-path__canvas">
        {nodes.map((node, index) => (
          <div className="mr-route-path__segment" key={`${node.kind}-${node.label}`}>
            <div className={`mr-route-node mr-route-node--${node.kind}`}>
              <span className="mr-route-node__dot" aria-hidden="true" />
              <div>
                <strong>{node.label}</strong>
                {node.meta && <small>{node.meta}</small>}
              </div>
            </div>
            {index < nodes.length - 1 && <span className="mr-route-path__link" aria-hidden="true" />}
          </div>
        ))}
      </div>
      {caption && <p className="mr-route-path__caption">{caption}</p>}
    </div>
  );
}
