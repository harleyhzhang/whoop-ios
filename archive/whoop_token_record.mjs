/** Decode both plaintext env files and security(1)'s hex-encoded Keychain data. */
export function parseTokenRecord(record) {
  let text = record.trim();
  if (/^(?:[0-9a-fA-F]{2})+$/.test(text)) {
    text = Buffer.from(text, "hex").toString("utf8").replace(/\0+$/, "");
  }
  return Object.fromEntries(text.split(/\r?\n/)
    .filter((line) => line && !line.startsWith("#") && line.includes("="))
    .map((line) => {
      const index = line.indexOf("=");
      return [line.slice(0, index), line.slice(index + 1)];
    }));
}
