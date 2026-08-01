import {
  HeadContent,
  Outlet,
  Scripts,
  createRootRoute,
} from "@tanstack/react-router";
import styles from "../styles.css?url";

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: "Portly — One supervisor for every local server" },
      {
        name: "description",
        content:
          "Portly gives AI coding agents one shared source of truth for local development servers, ports, health, and logs.",
      },
      { name: "theme-color", content: "#07090d" },
      { property: "og:type", content: "website" },
      { property: "og:site_name", content: "Portly" },
      {
        property: "og:title",
        content: "Portly — Stop launching the same app five times",
      },
      {
        property: "og:description",
        content:
          "One native macOS supervisor gives every AI agent the same live context for local servers.",
      },
      { property: "og:url", content: "https://portly.melvynx.dev" },
      {
        property: "og:image",
        content: "https://portly.melvynx.dev/og-portly.png",
      },
      { name: "twitter:card", content: "summary_large_image" },
    ],
    links: [
      { rel: "stylesheet", href: styles },
      { rel: "icon", href: "/favicon.svg", type: "image/svg+xml" },
      { rel: "manifest", href: "/site.webmanifest" },
      { rel: "canonical", href: "https://portly.melvynx.dev" },
    ],
  }),
  component: RootLayout,
});

function RootLayout() {
  return (
    <html lang="en">
      <head>
        <HeadContent />
      </head>
      <body>
        <a className="skip-link" href="#main-content">
          Skip to content
        </a>
        <Outlet />
        <Scripts />
      </body>
    </html>
  );
}
