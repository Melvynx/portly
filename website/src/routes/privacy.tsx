import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/privacy")({
  head: () => ({
    meta: [
      { title: "Privacy Policy — Portly" },
      {
        name: "description",
        content:
          "Privacy policy for the Portly macOS app and its sandboxed App Store companion.",
      },
    ],
    links: [
      {
        rel: "canonical",
        href: "https://portly.melvynx.dev/privacy",
      },
    ],
  }),
  component: PrivacyPolicy,
});

const sectionStyle = {
  display: "grid",
  gap: "0.75rem",
} as const;

function PrivacyPolicy() {
  return (
    <main
      id="main-content"
      style={{
        width: "min(720px, calc(100% - 2rem))",
        margin: "0 auto",
        padding: "4rem 0",
        display: "grid",
        gap: "2rem",
      }}
    >
      <a href="/" style={{ color: "inherit" }}>
        ← Portly
      </a>

      <header style={sectionStyle}>
        <h1>Portly Privacy Policy</h1>
        <p>Effective August 2, 2026</p>
      </header>

      <section style={sectionStyle}>
        <h2>Website analytics</h2>
        <p>
          The Portly website uses our self-hosted analytics service to measure
          anonymous page views and aggregate daily visitor counts. It uses no
          cookies, advertising profiles, session replay, or stable visitor
          identifier.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2>Direct app analytics</h2>
        <p>
          The direct-download Portly app sends two anonymous usage events to our
          self-hosted analytics service: one when an installation is first seen
          and one when the app launches. The event payload contains only the
          Portly version, macOS version, and processor architecture.
        </p>
        <p>
          Like any web request, the source IP address and User-Agent reach the
          analytics server and are processed to calculate aggregate visitor
          counts. Portly sends no cookie or stable device identifier.
        </p>
        <p>
          Portly does not send names, email addresses, device identifiers,
          project names, paths, commands, environment variables, server logs, or
          file contents. Analytics uses no cookies, advertising profiles,
          session replay, or third-party analytics provider.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2>App Store companion</h2>
        <p>
          Portly Companion does not collect, store, sell, or transmit personal
          data to the developer or to third parties. It does not include the
          anonymous analytics used by the direct-download Portly app.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2>Local communication</h2>
        <p>
          The app communicates only with an existing Portly service running on
          your Mac through the loopback address 127.0.0.1. It uses that local
          connection to display server status and send start, stop, and restart
          requests. These requests do not leave your Mac.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2>Local files</h2>
        <p>
          Portly Companion is sandboxed and does not read project files. The
          separately installed Portly service may keep its configuration and
          server logs locally on your Mac. Those files are controlled by you and
          are not uploaded by Portly Companion.
        </p>
      </section>

      <section style={sectionStyle}>
        <h2>Support</h2>
        <p>
          For privacy or support questions, open an issue in the public Portly
          repository on GitHub.
        </p>
        <p>
          <a href="https://github.com/Melvynx/portly/issues">
            github.com/Melvynx/portly/issues
          </a>
        </p>
      </section>
    </main>
  );
}
