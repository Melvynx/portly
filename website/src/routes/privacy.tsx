import { createFileRoute } from "@tanstack/react-router";

export const Route = createFileRoute("/privacy")({
  head: () => ({
    meta: [
      { title: "Privacy Policy — Portly Companion" },
      {
        name: "description",
        content:
          "Privacy policy for Portly Companion, the sandboxed macOS companion for a local Portly service.",
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
        <h1>Portly Companion Privacy Policy</h1>
        <p>Effective August 1, 2026</p>
      </header>

      <section style={sectionStyle}>
        <h2>Data collection</h2>
        <p>
          Portly Companion does not collect, store, sell, or transmit personal
          data to the developer or to third parties.
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
