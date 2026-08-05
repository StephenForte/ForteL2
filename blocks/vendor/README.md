# Vendored frontend dependencies

## ethers@6.13.7

- File: `ethers-6.13.7.min.js` (self-contained ESM from npm `dist/ethers.min.js`; filename tracks the vendored version — see `dapp/vendor/README.md`)
- sha384: `/xV0oGbwIQawOAr9BH+kez5JFLONy+/GXmM/oC6IuPjv9l+b/3gJSyit1wKY6DJK`

Bump deliberately: replace the file (and the copy at `viewer/vendor/ethers-6.13.7.min.js`), update this sha384, smoke guestbook connect/sign. Keep CSP `script-src 'self'` (no CDN scripts).
