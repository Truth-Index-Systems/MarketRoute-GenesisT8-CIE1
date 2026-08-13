import { Icon, type IconName } from "@/ui/icons";
export function EmptyState({icon="database",title,body}:{icon?:IconName;title:string;body:string}){return <div className="mr-empty-state"><span><Icon name={icon} size={20}/></span><strong>{title}</strong><p>{body}</p></div>}
