import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "MarketRoute — Know who to target and the route in",
  description: "MarketRoute researches your market, qualifies commercial reality and maps evidence-backed routes to the people and channels worth pursuing.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
