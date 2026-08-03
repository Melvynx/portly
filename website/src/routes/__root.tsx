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
      { title: "Portly: one supervisor for every local server" },
      {
        name: "description",
        content:
          "Portly runs each local development server once, then gives every AI agent the same live state: port, PID, health, and logs.",
      },
      { name: "theme-color", content: "#090b0d" },
      { property: "og:type", content: "website" },
      { property: "og:site_name", content: "Portly" },
      {
        property: "og:title",
        content: "Portly: your agents keep starting the same server",
      },
      {
        property: "og:description",
        content:
          "A native macOS supervisor that runs each local server once and reports its port, PID, health, and logs as JSON.",
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
        <script
          defer
          src="/stats/script.js"
          data-website-id="f643140d-b584-4501-aa0c-6d97e7673fe3"
          data-host-url="/stats"
        />
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
