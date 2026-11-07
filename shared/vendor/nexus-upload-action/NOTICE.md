# Vendored: Nexus-Mods/upload-action

`index.js` is the compiled GitHub Actions bundle from
https://github.com/Nexus-Mods/upload-action, pinned at tag `v1.0.0-beta.11`
(`https://raw.githubusercontent.com/Nexus-Mods/upload-action/v1.0.0-beta.11/dist/index.js`).

It's vendored here so `publish-nexus-local.ps1` can run the same, officially-maintained Nexus
Mods v3 Upload API client (multipart upload, presigned S3 parts, finalise/poll) directly with
Node when a repo's GitHub Actions workflow isn't available or `/publish --local` is used —
without reimplementing that flow by hand.

It is invoked exactly like a GitHub Action would: `INPUT_*` environment variables for its inputs,
`GITHUB_OUTPUT` pointed at a temp file for its outputs. See `publish-nexus-local.ps1`.

Treat it as a trusted third-party binary, same trust boundary as using the action in CI. To
update: re-download `dist/index.js` from a newer tag and bump the version noted above.
