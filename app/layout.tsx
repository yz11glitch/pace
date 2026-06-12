import type { Metadata } from "next";
import "./globals.css";
import { StoreProvider } from "./components/StoreProvider";

export const metadata: Metadata = {
  title: "Pace — Money Tracker",
  description: "Clean money tracking focused on spending pace",
  viewport: "width=device-width, initial-scale=1, maximum-scale=1",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>
        <StoreProvider>
          {children}
        </StoreProvider>
      </body>
    </html>
  );
}
