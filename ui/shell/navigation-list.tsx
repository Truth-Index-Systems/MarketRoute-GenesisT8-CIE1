"use client";
import { usePathname } from "next/navigation";
import { Icon } from "@/ui/icons";
import { shellNavigation } from "@/ui/shell/navigation";

export function NavigationList({mobile=false}:{mobile?:boolean}){
  const pathname=usePathname();
  return <nav className={mobile?"mr-mobile-nav__links":"mr-sidebar__nav"} aria-label="Primary navigation">{shellNavigation.map((item)=>{const active=item.href==="/app"?pathname==="/app":pathname.startsWith(item.href);return <a className={`mr-nav-item ${active?"mr-nav-item--active":""}`} aria-current={active?"page":undefined} href={item.href} key={item.label}><Icon name={item.icon} size={17}/><span>{item.label}</span></a>;})}</nav>;
}
