/**
 * Generates a fresh random Ed25519 keypair for LOCAL/PRODUCTION use.
 * Run with: npm run keygen
 *
 * The private key printed here is what goes into:
 *   wrangler secret put LICENSE_ED25519_PRIVATE_KEY
 * (as the hex string, no 0x prefix). The public key hex is what gets baked
 * into the Swift verifier -- it is NOT secret, share it freely.
 *
 * This script deliberately does not write anything to disk. Copy the
 * private key directly into `wrangler secret put` and then close the
 * terminal scrollback; don't leave it sitting in a file.
 */
import * as ed from "@noble/ed25519";
import { sha512 } from "@noble/hashes/sha512";

ed.etc.sha512Sync = (...messages: Uint8Array[]) => sha512(ed.etc.concatBytes(...messages));

function toHex(bytes: Uint8Array): string {
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const privateKey = ed.utils.randomPrivateKey();
const publicKey = ed.getPublicKey(privateKey);

console.log("Ed25519 keypair generated. Treat the private key as a production secret.\n");
console.log("PRIVATE KEY (hex, 32 bytes) -- wrangler secret put LICENSE_ED25519_PRIVATE_KEY:");
console.log(toHex(privateKey));
console.log("\nPUBLIC KEY (hex, 32 bytes) -- bake this into the Swift verifier, not secret:");
console.log(toHex(publicKey));
