import type { IconName } from "@/ui/icons";
export interface ShellNavigationItem { label:string; icon:IconName; href:string; }
export const shellNavigation:ShellNavigationItem[]=[
  {label:"Command Centre",icon:"command",href:"/app"},
  {label:"Campaigns",icon:"campaigns",href:"/app/campaigns"},
  {label:"Companies",icon:"companies",href:"/app/companies"},
  {label:"Opportunities",icon:"opportunities",href:"/app/opportunities"},
  {label:"Research",icon:"research",href:"/app/research"},
  {label:"Engagement",icon:"engagement",href:"/app/engagement"},
  {label:"Plan",icon:"shield",href:"/app/plans"},
];
