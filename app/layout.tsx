import type { Metadata, Viewport } from "next";
import "./globals.css";
import { StoreProvider } from "./components/StoreProvider";

export const metadata: Metadata = {
  title: "Pace — Money Tracker",
  description: "Clean money tracking focused on spending pace",
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
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
