/**
 * Regenerates TEST_VECTORS.md deterministically. Run with: npm run vectors
 *
 * The keypair here is a fixed TEST keypair only (derived from a known
 * passphrase, see below) -- never use it for anything real. It exists so
 * the Swift verifier and this worker can both sign/verify the exact same
 * strings and prove the two implementations agree byte-for-byte.
 */
import * as ed from "@noble/ed25519";
import { sha256 } from "@noble/hashes/sha256";
import { sha512 } from "@noble/hashes/sha512";
import { writeFileSync } from "node:fs";
import { signLicense, type LicenseFields } from "../src/license.js";

ed.etc.sha512Sync = (...messages: Uint8Array[]) => sha512(ed.etc.concatBytes(...messages));

function toHex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Deterministic, reproducible, NOT secret: private key = SHA-256 of a fixed
// passphrase. Anyone can regenerate the exact same keypair from the
// passphrase alone, which is the point -- it lets both sides (this worker,
// the Swift verifier, and this script) derive it independently and agree.
const TEST_PASSPHRASE = "PeekLicenseKit-TEST-KEY-DO-NOT-USE-IN-PRODUCTION";
const privateKey = sha256(new TextEncoder().encode(TEST_PASSPHRASE));
const publicKey = ed.getPublicKey(privateKey);

const vectors: Array<{ label: string; fields: LicenseFields }> = [
  {
    label: "1 -- ASCII email",
    fields: {
      schemaVersion: 1,
      productId: 1,
      issuedAt: 1_732_000_000,
      polarKey: "POLAR-AB12-CD34-EF56-7890",
      email: "mario.rossi@example.com",
    },
  },
  {
    label: "2 -- non-ASCII UTF-8 email",
    fields: {
      schemaVersion: 1,
      productId: 1,
      issuedAt: 1_690_000_000,
      polarKey: "POLAR-0000-1111-2222-3333",
      email: "società@ésempio.it",
    },
  },
  {
    label: "3 -- another ASCII case",
    fields: {
      schemaVersion: 1,
      productId: 1,
      issuedAt: 1_800_000_000,
      polarKey: "POLAR-ZZZZ-9999-AAAA-BBBB",
      email: "qa+peek3d@anthropic.test",
    },
  },
];

let out = "# License string test vectors\n\n";
out += "Regenerate with `npm run vectors`. Used to cross-check this worker's\n";
out += "signing against the Swift verifier -- both must produce byte-identical\n";
out += "strings for the same inputs and the same test keypair.\n\n";
out += "## Test keypair (NOT secret, deterministic, for cross-checking only)\n\n";
out += `Derived as \`SHA-256("${TEST_PASSPHRASE}")\`.\n\n`;
out += `- Private key (hex, 32 bytes): \`${toHex(privateKey)}\`\n`;
out += `- Public key (hex, 32 bytes): \`${toHex(publicKey)}\`\n\n`;
out += "## Vectors\n\n";

for (const { label, fields } of vectors) {
  const licenseString = await signLicense(fields, privateKey);
  out += `### Vector ${label}\n\n`;
  out += "Input:\n\n";
  out += "```json\n" + JSON.stringify(fields, null, 2) + "\n```\n\n";
  out += "Output license string:\n\n";
  out += "```\n" + licenseString + "\n```\n\n";
}

// Run via `npm run vectors` from the project root, so cwd-relative is fine.
writeFileSync("TEST_VECTORS.md", out);
console.log(out);
console.log("Wrote TEST_VECTORS.md");
