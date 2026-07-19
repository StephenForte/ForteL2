# Pipeline viewer vendor

`ethers-6.13.5.min.js` is a **copy** of `dapp/vendor/ethers-6.13.5.min.js` (self-contained ESM).
A symlink is not used: `serve-viewer.sh` roots HTTP at `viewer/`, and checkouts with
`core.symlinks=false` would otherwise serve the symlink target path as a one-line text
blob — invalid JavaScript that breaks `viewer/app.js` before any RPC polling.

When bumping ethers, replace both files and update the sha384 in `dapp/vendor/README.md`.
Keep CSP `script-src 'self'` (no CDN scripts).
