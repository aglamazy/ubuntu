// azure-to-env.ts
import { readFileSync, writeFileSync } from "fs";

function quoteIfNeeded(v: string) {
  const needsQuotes = /[\s#"'`]|^$/.test(v) || v.includes("\n") || v.includes("\r") || v.includes("=");
  if (!needsQuotes) return v;
  return `"${v.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\r?\n/g, "\\n")}"`;
}

function sanitizeKey(k: string) {
  return k.replace(/[^A-Z0-9_]/gi, "_");
}

const [,, inPath = "azure-settings.json", outPath = ".env"] = process.argv;

const raw = readFileSync(inPath, "utf8");
const arr: Array<{name:string; value:string; slotSetting?:boolean}> = JSON.parse(raw);

const lines = arr
  .filter(x => x && typeof x.name === "string")
  .map(({ name, value }) => `${sanitizeKey(name)}=${quoteIfNeeded(String(value ?? ""))}`)
  .join("\n") + "\n";

writeFileSync(outPath, lines, "utf8");
console.log(`Wrote ${outPath} with ${arr.length} vars`);

