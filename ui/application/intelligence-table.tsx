import type { ReactNode } from "react";
export function IntelligenceTable({head,children}:{head:string[];children:ReactNode}){return <div className="mr-table-wrap"><table className="mr-intelligence-table"><thead><tr>{head.map((h)=><th key={h}>{h}</th>)}</tr></thead><tbody>{children}</tbody></table></div>}
