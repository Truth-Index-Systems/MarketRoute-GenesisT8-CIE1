"use client";
import { usePathname } from "next/navigation";
import { Icon } from "@/ui/icons";
const labels:Array<[string,string,string]>=[
  ["/app/campaigns","Campaign intelligence","Campaigns"],["/app/companies","Market intelligence","Companies"],["/app/opportunities","Commercial intelligence","Opportunities"],["/app/research","Genesis","Research"],["/app/engagement","Execution intelligence","Engagement"],["/app","Market intelligence","Command Centre"],
];
export function WorkspaceTopbar({userEmail}:{userEmail:string|null}){const pathname=usePathname();const match=labels.find(([path])=>path==="/app"?pathname==="/app":pathname.startsWith(path))??labels.at(-1)!;return <header className="mr-topbar"><div className="mr-topbar__context"><span>{match[1]}</span><strong>{match[2]}</strong></div><div className="mr-topbar__tools"><span className="mr-topbar__user">{userEmail??"Workspace member"}</span><div className="mr-avatar" aria-label="Workspace account">{(userEmail??"MR").slice(0,2).toUpperCase()}</div><form action="/api/session/logout" method="post"><button className="mr-icon-button" type="submit" aria-label="Sign out"><Icon name="arrow" size={16}/></button></form></div></header>}
