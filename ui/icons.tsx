import type { SVGProps } from "react";

export type IconName =
  | "command"
  | "campaigns"
  | "companies"
  | "opportunities"
  | "research"
  | "engagement"
  | "chevron"
  | "arrow"
  | "spark"
  | "shield"
  | "database"
  | "route"
  | "clock"
  | "check"
  | "search"
  | "menu"
  | "user"
  | "mail"
  | "phone"
  | "copy"
  | "external"
  | "warning";

interface IconProps extends SVGProps<SVGSVGElement> {
  name: IconName;
  size?: number;
}

const paths: Record<IconName, React.ReactNode> = {
  command: <><rect x="3" y="3" width="7" height="7" rx="1.5" /><rect x="14" y="3" width="7" height="7" rx="1.5" /><rect x="3" y="14" width="7" height="7" rx="1.5" /><rect x="14" y="14" width="7" height="7" rx="1.5" /></>,
  campaigns: <><path d="M4 5.5h16v13H4z" /><path d="M8 9h8M8 13h5" /></>,
  companies: <><path d="M5 21V7l7-4 7 4v14" /><path d="M9 21v-5h6v5M8 9h.01M12 9h.01M16 9h.01M8 13h.01M12 13h.01M16 13h.01" /></>,
  opportunities: <><circle cx="12" cy="12" r="8" /><path d="m9 12 2 2 4-5" /></>,
  research: <><circle cx="10.5" cy="10.5" r="5.5" /><path d="m15 15 5 5M10.5 7.5v6M7.5 10.5h6" /></>,
  engagement: <><path d="M4 5h16v12H8l-4 3V5Z" /><path d="M8 9h8M8 13h5" /></>,
  chevron: <path d="m9 6 6 6-6 6" />,
  arrow: <><path d="M5 12h14" /><path d="m14 7 5 5-5 5" /></>,
  spark: <><path d="m12 3 1.4 4.1L17.5 8.5l-4.1 1.4L12 14l-1.4-4.1-4.1-1.4 4.1-1.4L12 3Z" /><path d="m18 14 .8 2.2L21 17l-2.2.8L18 20l-.8-2.2L15 17l2.2-.8L18 14Z" /></>,
  shield: <><path d="M12 3 5 6v5c0 4.6 2.8 7.7 7 10 4.2-2.3 7-5.4 7-10V6l-7-3Z" /><path d="m9 12 2 2 4-5" /></>,
  database: <><ellipse cx="12" cy="5" rx="7" ry="3" /><path d="M5 5v7c0 1.7 3.1 3 7 3s7-1.3 7-3V5M5 12v7c0 1.7 3.1 3 7 3s7-1.3 7-3v-7" /></>,
  route: <><circle cx="5" cy="17" r="2" /><circle cx="12" cy="7" r="2" /><circle cx="19" cy="17" r="2" /><path d="m6.2 15.4 4.6-6.8M13.2 8.6l4.6 6.8" /></>,
  clock: <><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></>,
  check: <path d="m5 12 4 4L19 6" />,
  search: <><circle cx="10.5" cy="10.5" r="5.5" /><path d="m15 15 5 5" /></>,
  menu: <><path d="M4 7h16M4 12h16M4 17h16" /></>,
  user: <><circle cx="12" cy="8" r="3.5" /><path d="M5 20c.8-4.2 3.2-6.3 7-6.3s6.2 2.1 7 6.3" /></>,
  mail: <><rect x="3" y="5" width="18" height="14" rx="2" /><path d="m4 7 8 6 8-6" /></>,
  phone: <path d="M7.2 3.8 4.8 5.1c-.8.4-1.1 1.3-.8 2.2 1.8 5.6 6.1 9.9 11.7 11.7.9.3 1.8 0 2.2-.8l1.3-2.4c.4-.8.2-1.7-.5-2.2l-2.7-2c-.7-.5-1.6-.4-2.2.2l-1.1 1.1a13.4 13.4 0 0 1-4.6-4.6l1.1-1.1c.6-.6.7-1.5.2-2.2l-2-2.7c-.5-.7-1.4-.9-2.2-.5Z" />,
  copy: <><rect x="8" y="8" width="11" height="11" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/></>,
  external: <><path d="M14 5h5v5"/><path d="m11 13 8-8"/><path d="M19 13v5a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2h5"/></>,
  warning: <><path d="M10.3 4.2 2.9 17a2 2 0 0 0 1.7 3h14.8a2 2 0 0 0 1.7-3L13.7 4.2a2 2 0 0 0-3.4 0Z"/><path d="M12 9v4M12 17h.01"/></>,
};

export function Icon({ name, size = 18, ...props }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.7"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      {...props}
    >
      {paths[name]}
    </svg>
  );
}
