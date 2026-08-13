import type { AnchorHTMLAttributes, ButtonHTMLAttributes, ReactNode } from "react";

interface CommonButtonProps {
  children: ReactNode;
  variant?: "primary" | "secondary" | "ghost";
  icon?: ReactNode;
}

export function Button({ children, variant = "secondary", icon, ...props }: CommonButtonProps & ButtonHTMLAttributes<HTMLButtonElement>) {
  return (
    <button className={`mr-button mr-button--${variant}`} {...props}>
      {children}
      {icon}
    </button>
  );
}

export function ButtonLink({ children, variant = "secondary", icon, ...props }: CommonButtonProps & AnchorHTMLAttributes<HTMLAnchorElement>) {
  return (
    <a className={`mr-button mr-button--${variant}`} {...props}>
      {children}
      {icon}
    </a>
  );
}
