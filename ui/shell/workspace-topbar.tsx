"use client";
import { usePathname } from "next/navigation";
const labels:Array<[string,string,string]>=[
  ["/app/campaigns","MarketRoute","Markets"],["/app/companies","MarketRoute","Companies"],["/app/opportunities","MarketRoute","Opportunities"],["/app/engagement","MarketRoute","Outreach"],["/app/plans","MarketRoute","Plan & billing"],["/app","MarketRoute","Overview"],
];
export function WorkspaceTopbar({userEmail}:{userEmail:string|null}){const pathname=usePathname();const match=labels.find(([path])=>path==="/app"?pathname==="/app":pathname.startsWith(path))??labels.at(-1)!;return <header className="mr-topbar"><div className="mr-topbar__context"><span>{match[1]}</span><i>/</i><strong>{match[2]}</strong></div><div className="mr-topbar__tools"><a className="mr-topbar__help" href="/support">Help</a><span className="mr-topbar__user">{userEmail??"Workspace member"}</span><form action="/api/session/logout" method="post"><button className="mr-topbar__signout" type="submit">Sign out</button></form></div></header>}
