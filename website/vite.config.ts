import { tanstackStart } from "@tanstack/react-start/plugin/vite";
import react from "@vitejs/plugin-react";
import { nitro } from "nitro/vite";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { defineConfig } from "vite";

const versionSource = readFileSync(
  resolve(import.meta.dirname, "../Sources/PortlyCore/Version.swift"),
  "utf8",
);
const portlyVersion = versionSource.match(/"([0-9][^"]*)"/)?.[1];

if (!portlyVersion) {
  throw new Error("Unable to read Portly version from Version.swift");
}

export default defineConfig({
  define: {
    __PORTLY_VERSION__: JSON.stringify(portlyVersion),
  },
  server: {
    port: Number(process.env.PORT) || 3000,
    watch: { ignored: ["**/.output/**"] },
  },
  plugins: [
    tanstackStart({
      prerender: {
        enabled: true,
        crawlLinks: true,
        autoSubfolderIndex: true,
      },
    }),
    nitro(),
    react(),
  ],
});
