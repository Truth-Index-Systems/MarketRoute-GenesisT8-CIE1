import type { IconName } from "@/ui/icons";
export interface ShellNavigationItem { label:string; icon:IconName; href:string; }
export const shellNavigation:ShellNavigationItem[]=[
  {label:"Overview",icon:"command",href:"/app"},
  {label:"Markets",icon:"campaigns",href:"/app/campaigns"},
  {label:"Companies",icon:"companies",href:"/app/companies"},
  {label:"Opportunities",icon:"opportunities",href:"/app/opportunities"},
  {label:"Outreach",icon:"engagement",href:"/app/engagement"},
  {label:"Plan & billing",icon:"shield",href:"/app/plans"},
];
