import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "MarketRoute V2",
  description: "Constitutional foundation for MarketRoute V2.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
