# StremioCast-iOS

Chromecast sender integration for the native iOS StremioX client.

## Current implementation

- Google Cast iOS Sender SDK 4.8.6 (Swift Package Manager).
- Cast context initialized at native app startup.
- Native Cast picker in the player.
- Selected media is prepared before the Cast picker opens, then loaded after the Cast session starts.
- GCKRequestDelegate tracks media-load acceptance and failures.
- GCKRemoteMediaClientListener tracks receiver playback state.
- The local player pauses only after the receiver reports that playback has started.
- iPhone-local HTTP streams can be exposed through a short-lived, token-protected Wi-Fi relay pinned to one URL; GET, HEAD and byte-range requests are forwarded, along with the stream's player headers.
- MIME type inference covers common progressive video, HLS, DASH and audio extensions.
- Bonjour/local-network permission entries are included.

## Source provenance and freshness

The iOS native UI/player is based on the community native StremioX project at
https://github.com/TV46/stremiox. The Actions workflow checks out its current main branch for each
build. Its Rust bridge uses the official Stremio/stremio-core development branch; the workflow
resolves that branch at build time so the app compiles against the latest official core source.

The official Stremio/stremio-web React application is a separate UI and is not the native SwiftUI
player being compiled here. Its current development branch is useful as an upstream behavior and
reference source, but replacing the native client with it would be a different architecture, not a
safe source update.

## Known limits

- No transcoding.
- The Chromecast receiver must be able to reach the media URL directly.
- The local relay is limited to one selected HTTP source, uses the iPhone Wi-Fi interface, and is revoked when the Cast session ends (or after its expiry).
- Torrent streams, DRM, local sources that require unsupported schemes, and URLs requiring player-only behavior may still fail. The relay does not transcode or turn the iPhone into a general-purpose proxy.
- Some media hosts block Chromecast user agents or cross-device requests.
- Real-device playback must still be verified on the user's Chromecast.

## Build

GitHub Actions → StremioCast iOS IPA → Run workflow. Download the unsigned IPA artifact
after a successful run, then sign it with a provisioning profile matching
com.stremiox.app.native.

## References

- https://developers.google.com/cast/docs/ios_sender/integrate
- https://developers.google.com/cast/docs/reference/ios
- https://github.com/googlecast/google-cast-ios-sdk
