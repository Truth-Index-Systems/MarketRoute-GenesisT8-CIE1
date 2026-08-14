import { Icon, type IconName } from "@/ui/icons";
export interface RouteNodeView {
  label: string;
  meta?: string;
  kind: "company" | "unit" | "person" | "channel";
}

interface RoutePathProps {
  nodes: RouteNodeView[];
  caption?: string;
}

const nodeIcon: Record<RouteNodeView["kind"], IconName> = { company: "companies", unit: "route", person: "user", channel: "mail" };

const nodeKind: Record<RouteNodeView["kind"], string> = {
  company: "Company",
  unit: "Decision area",
  person: "Person",
  channel: "Access point",
};

export function RoutePath({ nodes, caption }: RoutePathProps) {
  return (
    <div className="mr-route-path">
      <div className="mr-route-path__canvas">
        {nodes.map((node, index) => (
          <div className="mr-route-path__segment" key={`${node.kind}-${node.label}`}>
            <div className={`mr-route-node mr-route-node--${node.kind}`}>
              <div className="mr-route-node__top"><span className={`mr-route-node__icon mr-route-node__icon--${node.kind}`}><Icon name={nodeIcon[node.kind]} size={15}/></span><span className="mr-route-node__kind">{nodeKind[node.kind]}</span></div>
              <div>
                <strong>{node.label}</strong>
                {node.meta && <small>{node.meta}</small>}
              </div>
            </div>
            {index < nodes.length - 1 && <span className="mr-route-path__link" aria-hidden="true"><i />→</span>}
          </div>
        ))}
      </div>
      {caption && <p className="mr-route-path__caption">{caption}</p>}
    </div>
  );
}
