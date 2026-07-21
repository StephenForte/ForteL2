import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { trimToUtf8Bytes, utf8ByteLength } from "./lib.js";

describe("utf8ByteLength", () => {
  it("counts ASCII as one byte each", () => {
    assert.equal(utf8ByteLength("hello"), 5);
  });
  it("counts multibyte glyphs by UTF-8 bytes", () => {
    assert.equal(utf8ByteLength("é"), 2); // C3 A9
    assert.equal(utf8ByteLength("你"), 3);
    assert.equal(utf8ByteLength("💩"), 4);
  });
  it("treats nullish as empty", () => {
    assert.equal(utf8ByteLength(null), 0);
    assert.equal(utf8ByteLength(undefined), 0);
  });
});

describe("trimToUtf8Bytes", () => {
  it("returns input when already under budget", () => {
    assert.equal(trimToUtf8Bytes("abc", 10), "abc");
  });
  it("trims ASCII to exact budget", () => {
    assert.equal(trimToUtf8Bytes("abcdefghij", 5), "abcde");
  });
  it("does not leave orphan UTF-16 surrogates when trimming emoji", () => {
    // 3 emoji = 12 UTF-8 bytes; budget 10 keeps two full emoji (8 bytes).
    const trimmed = trimToUtf8Bytes("💩💩💩", 10);
    assert.equal(trimmed, "💩💩");
    assert.equal(utf8ByteLength(trimmed), 8);
    // No lone surrogates
    assert.ok([...trimmed].every((ch) => ch.codePointAt(0) > 0xffff || ch.length === 1));
  });
  it("trims mixed ASCII + multibyte without exceeding budget", () => {
    // "a" (1) + "é" (2) + "b" (1) + "é" (2) = 6; budget 4 → "a" + "é" + "b"
    assert.equal(trimToUtf8Bytes("aébé", 4), "aéb");
    assert.equal(utf8ByteLength(trimToUtf8Bytes("aébé", 4)), 4);
  });
  it("returns empty for non-positive budgets", () => {
    assert.equal(trimToUtf8Bytes("abc", 0), "");
    assert.equal(trimToUtf8Bytes("abc", -1), "");
  });
});
