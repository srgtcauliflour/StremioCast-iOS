# StremioCast-iOS
Chromecast integration overlay for [StremioX](https://github.com/TV46/stremiox).

Milestone: Cast Sender SDK 4.8.6 package, Cast context startup, Cast picker button in native iOS player, current stream URL queued for Default Media Receiver, Bonjour and local-network permission keys, and Actions unsigned IPA packaging.

Prototype constraints: direct HTTP(S) stream handoff only; streams requiring player headers, torrents, localhost, and some authenticated sources may not work. No transcoding is performed. The Actions workflow applies this overlay to the current upstream StremioX source, so upstream build dependencies or API changes may cause build adjustments.

Build: GitHub Actions → “StremioCast iOS IPA” → Run workflow. Download the IPA artifact on success.

SDK: https://github.com/googlecast/google-cast-ios-sdk
Docs: https://developers.google.com/cast/docs/ios_sender/integrate
