import type { Metadata, Viewport } from "next";
import "./globals.css";
import { StoreProvider } from "./components/StoreProvider";

export const metadata: Metadata = {
  title: "Pace — Money Tracker",
  description: "Clean money tracking focused on spending pace",
  manifest: "/manifest.webmanifest",
  icons: {
    // favicon-32.png: export public/pace-icon-favicon.svg at 32×32
    icon: [{ url: "/favicon-32.png", sizes: "32x32", type: "image/png" }],
    // apple-touch-icon.png: export public/pace-icon.svg at 180×180
    apple: [{ url: "/apple-touch-icon.png", sizes: "180x180", type: "image/png" }],
  },
  appleWebApp: {
    title: "Pace",
    statusBarStyle: "default",
    capable: true,
  },
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
