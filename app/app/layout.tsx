import type { ReactNode } from "react";
import { AppShell } from "@/ui";
import { workspaceSessionOrRedirect } from "@/app/app/_lib/session";
export default async function ProductLayout({children}:Readonly<{children:ReactNode}>){const {session,workspace}=await workspaceSessionOrRedirect();return <AppShell workspace={{organisationId:workspace.organisationId,name:workspace.organisation.name,role:workspace.role}} workspaces={session.memberships.map((m)=>({organisationId:m.organisationId,name:m.organisation.name,role:m.role}))} userEmail={session.user.email}>{children}</AppShell>}
