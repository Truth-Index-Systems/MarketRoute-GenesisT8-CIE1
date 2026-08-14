import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "MarketRoute — Know who to target, why, and how to reach them",
  description: "MarketRoute researches companies, verifies commercial fit and maps evidence-backed routes to the right buyers — turning market research into actionable B2B opportunities.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
