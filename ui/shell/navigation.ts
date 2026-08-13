import type { IconName } from "@/ui/icons";

export interface ShellNavigationItem {
  label: string;
  icon: IconName;
  href: string;
  enabled: boolean;
}

export const shellNavigation: ShellNavigationItem[] = [
  { label: "Command Centre", icon: "command", href: "/app", enabled: true },
  { label: "Campaigns", icon: "campaigns", href: "/app/campaigns", enabled: false },
  { label: "Companies", icon: "companies", href: "/app/companies", enabled: false },
  { label: "Opportunities", icon: "opportunities", href: "/app/opportunities", enabled: false },
  { label: "Research", icon: "research", href: "/app/research", enabled: false },
  { label: "Engagement", icon: "engagement", href: "/app/engagement", enabled: false },
];
