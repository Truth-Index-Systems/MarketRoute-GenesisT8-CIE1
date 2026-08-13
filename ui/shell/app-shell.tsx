import type { ReactNode } from "react";
import { MarketRouteLogo } from "@/ui/brand/marketroute-logo";
import { Icon } from "@/ui/icons";
import { shellNavigation } from "@/ui/shell/navigation";

interface AppShellProps {
  children: ReactNode;
}

function NavigationList({ mobile = false }: { mobile?: boolean }) {
  return (
    <nav className={mobile ? "mr-mobile-nav__links" : "mr-sidebar__nav"} aria-label="Primary navigation">
      {shellNavigation.map((item, index) => {
        const content = (
          <>
            <Icon name={item.icon} size={17} />
            <span>{item.label}</span>
            {!item.enabled && <small>Build 15</small>}
          </>
        );
        if (!item.enabled) {
          return (
            <span className="mr-nav-item mr-nav-item--disabled" aria-disabled="true" key={item.label}>
              {content}
            </span>
          );
        }
        return (
          <a className={`mr-nav-item ${index === 0 ? "mr-nav-item--active" : ""}`} href={item.href} key={item.label}>
            {content}
          </a>
        );
      })}
    </nav>
  );
}

export function AppShell({ children }: AppShellProps) {
  return (
    <div className="mr-app-shell">
      <div className="mr-app-grid" aria-hidden="true" />
      <aside className="mr-sidebar">
        <a href="/" className="mr-sidebar__brand" aria-label="MarketRoute home">
          <MarketRouteLogo />
        </a>
        <div className="mr-sidebar__workspace">
          <span>Workspace</span>
          <strong>Truth Index Systems</strong>
        </div>
        <NavigationList />
        <div className="mr-sidebar__footer">
          <div className="mr-system-state">
            <span className="mr-system-state__pulse" aria-hidden="true" />
            <div>
              <strong>Genesis online</strong>
              <small>Design system preview</small>
            </div>
          </div>
          <a href="/design-system" className="mr-sidebar__utility">Design system <Icon name="chevron" size={14} /></a>
        </div>
      </aside>

      <div className="mr-app-main">
        <header className="mr-topbar">
          <div className="mr-topbar__mobile-brand">
            <MarketRouteLogo compact />
            <strong>MarketRoute</strong>
          </div>
          <div className="mr-topbar__context">
            <span>Market intelligence</span>
            <strong>Command Centre</strong>
          </div>
          <div className="mr-topbar__tools">
            <button className="mr-icon-button" type="button" aria-label="Search preview" disabled>
              <Icon name="search" size={17} />
            </button>
            <div className="mr-avatar" aria-label="Workspace account">TI</div>
          </div>
        </header>

        <details className="mr-mobile-nav">
          <summary aria-label="Open navigation"><Icon name="menu" size={18} /> Navigation</summary>
          <NavigationList mobile />
        </details>

        <main className="mr-app-content">{children}</main>
      </div>
    </div>
  );
}
