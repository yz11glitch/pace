import type { MetadataRoute } from "next";

export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "Pace — Money Tracker",
    short_name: "Pace",
    description: "Clean money tracking focused on spending pace",
    start_url: "/",
    display: "standalone",
    orientation: "portrait",
    background_color: "#FBF6EF",
    theme_color: "#C2683E",
    icons: [
      // Replace SVG entries with PNG once exports are ready (see public/pace-icon.svg)
      {
        src: "/pace-icon.svg",
        sizes: "any",
        type: "image/svg+xml",
        purpose: "any",
      },
      // Uncomment and export these PNGs from public/pace-icon.svg:
      // { src: "/icon-192.png", sizes: "192x192", type: "image/png", purpose: "any" },
      // { src: "/icon-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
    ],
  };
}
