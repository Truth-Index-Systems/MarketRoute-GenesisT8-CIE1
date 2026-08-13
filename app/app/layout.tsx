import type { ReactNode } from "react";
import { AppShell } from "@/ui";

export default function ProductLayout({ children }: Readonly<{ children: ReactNode }>) {
  return <AppShell>{children}</AppShell>;
}
