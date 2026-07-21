/**
 * Pure helpers for the Guestbook dApp (unit-tested; no DOM / RPC I/O).
 */

/** UTF-8 byte length of a JS string (matches Solidity `bytes(text).length`). */
export function utf8ByteLength(text) {
  return new TextEncoder().encode(text ?? "").length;
}

/**
 * Trim `text` to at most `maxBytes` UTF-8 bytes without splitting code points.
 * Uses code-point iteration so surrogate pairs (emoji) are removed as a unit.
 */
export function trimToUtf8Bytes(text, maxBytes) {
  const value = text ?? "";
  if (!Number.isFinite(maxBytes) || maxBytes < 0) return "";
  if (utf8ByteLength(value) <= maxBytes) return value;
  const chars = [...value];
  while (chars.length > 0 && utf8ByteLength(chars.join("")) > maxBytes) {
    chars.pop();
  }
  return chars.join("");
}
