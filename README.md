# Twitch Audio for Lyrion Music Server

Twitch Audio is an audio-only Twitch integration for Lyrion Music Server (LMS). It adds Twitch as an application in the LMS radio menu, allows users to find channels by login name, and plays both live broadcasts and available channel VODs on Squeezebox-compatible players.

The plugin does not pass Twitch's HLS media containers directly to the player. It resolves Twitch playback URLs, manages the HLS session inside LMS, extracts AAC audio from MPEG transport stream or fragmented MP4 segments, and exposes the result to LMS as a continuous ADTS-AAC byte stream.

## Features

- Search for a Twitch channel by login name or open a VOD directly by ID or URL.
- Play the channel's current live audio-only stream.
- Browse up to 100 highlights and archived broadcasts for a channel.
- Play and seek within Twitch VODs.
- Display the Twitch channel or VOD title, broadcaster name, artwork and exact AAC profile and sample rate.
- Preserve VOD duration and playback position across LMS stream recreation and player standby.
- Restore title, artist and artwork after standby.
- Process both MPEG-TS (`.ts`) and fragmented MP4 (`.mp4`) HLS media segments.
- Recognize Twitch copyright-muted segments such as `3-muted.ts` and `3-muted.mp4`.
- Keep live and VOD time semantics separate: live streams never expose a duration or seekable progress bar.

## Requirements

- Lyrion Music Server 7.7 or newer.
- A player capable of receiving AAC audio from LMS.
- Internet access from the LMS host to Twitch GraphQL, Usher and CDN endpoints.
- The Perl modules supplied by LMS, including its asynchronous HTTP, cache, JSON and URI support.

No Twitch account or OAuth login is required. The plugin uses Twitch's public web playback flow and requests audio-only HLS variants with the configured Twitch client ID.

## Installation

### LMS plugin repository

Add the following repository URL under **Settings > Plugins > Additional Repositories** in LMS:

```text
https://raw.githubusercontent.com/bungh0l10/twitchaudio/main/repo/repo.xml
```

After LMS has loaded the repository, select the Twitch plugin, apply the change and restart LMS when requested.

### Manual installation

Download `TWITCH.zip` from the matching GitHub release and install or extract it as an LMS plugin named `Twitch`. The resulting plugin directory must contain `install.xml`, `Plugin.pm`, `ProtocolHandler.pm`, `API.pm`, `HLSStream.pm`, and the `HLS/` and `HTML/` subdirectories.

Restart LMS after installation.

## User interface

The plugin registers an OPML-based application named **Twitch** in the LMS radio menu. Its root contains a combined channel and VOD search action.

The search accepts channel login names and the following direct VOD formats:

```text
2828694549
https://www.twitch.tv/videos/2828694549
https://twitch.tv/videos/2828694549
twitch:vod:2828694549
```

An explicit Twitch video URL or `twitch:vod:` URI is always treated as a VOD. A digits-only query is checked as a VOD ID first and falls back to a channel lookup if Twitch does not return a matching VOD.

Search input is allowlist-validated before any Twitch request is made. Channel logins must contain only lower-case ASCII letters, digits or underscores and must be 4–25 characters long. VOD IDs are limited to 1–20 decimal digits. Unsupported URLs, schemes, markup and other input are rejected; the plugin never interprets search text as code, a shell command or an arbitrary request URL.

Channel searching performs the following operations asynchronously:

1. The query is trimmed and converted to lower case.
2. Twitch is queried for the matching channel.
3. The channel is presented as a playable live item with its login, current stream title and profile image.
4. Twitch is queried for available highlights and archives.
5. Separate VOD menus are displayed when the corresponding category contains entries.

The initial channel lookup requests one VOD entry only to determine which VOD categories should be shown. Opening a category requests up to 100 entries and presents each VOD with its title, thumbnail and declared duration.

The internal playable URL formats are:

```text
twitch:live:<channel-login>
twitch:vod:<numeric-video-id>
```

These are logical LMS URLs. They are not direct Twitch media URLs.

## Playback pipeline

Playback is divided into four layers so Twitch API access, LMS protocol integration, HLS session management and container parsing remain independent.

```text
LMS UI item
  -> twitch:live:<login> or twitch:vod:<id>
  -> Twitch GraphQL playback token
  -> Twitch Usher master playlist
  -> audio_only media playlist
  -> internal twitchhls: URL
  -> HLS playlist/session coordinator
  -> MPEG-TS or fragmented MP4 AAC extraction
  -> continuous ADTS-AAC stream
  -> LMS player
```

### Twitch API access

`API.pm` implements all Twitch-facing requests using LMS's asynchronous HTTP client. Requests have a ten-second timeout and never block the LMS event loop.

The API layer provides:

- channel information and current stream metadata;
- highlight and archive listings;
- live playback access tokens;
- VOD playback access tokens;
- VOD title, owner, duration and thumbnail metadata;
- selection of the `audio_only` variant from the Twitch master playlist.

Live playback tokens are requested through `streamPlaybackAccessToken`. VOD playback uses Twitch's persisted `PlaybackAccessToken` GraphQL query. JSON boolean variables are encoded as actual JSON booleans rather than numeric values.

The returned access token and signature are passed to Twitch Usher. The resulting master playlist is scanned for an `audio_only` variant, and only that media playlist is handed to the LMS streaming layer.

### LMS protocol adaptation

`ProtocolHandler.pm` registers the logical `twitch:` protocol and translates it into an internal `twitchhls:` URL after resolving the Twitch media playlist.

The custom scheme prevents LMS's generic remote playlist scanner from treating the HLS media playlist as an ordinary M3U file containing independently playable tracks. The scan is explicitly configured as AAC audio with no video.

The handler also maintains a short-lived association between signed Twitch CDN URLs and their logical live or VOD identity. This is necessary because LMS may later request metadata using the resolved HLS URL rather than the original `twitch:` URL.

### HLS playlist parser

`HLS/Playlist.pm` is a state-free media-playlist parser. It resolves relative segment and initialization URLs against the playlist URL and interprets the tags needed by the stream coordinator:

- `EXT-X-MEDIA-SEQUENCE`
- `EXT-X-PLAYLIST-TYPE`
- `EXT-X-TARGETDURATION`
- `EXT-X-MAP`
- `EXT-X-DISCONTINUITY`
- `EXTINF`
- `EXT-X-ENDLIST`
- `EXT-X-TWITCH-ELAPSED-SECS`
- `EXT-X-TWITCH-TOTAL-SECS`

Each parsed segment contains its sequence number, absolute URL, duration, calculated timeline position, initialization URL, container hint, discontinuity flag and muted-state flag.

An `EVENT` playlist with a known Twitch total duration is considered seekable. It is considered complete once the final known segment reaches the advertised total duration, even if Twitch does not append `EXT-X-ENDLIST`. A normal playlist with `EXT-X-ENDLIST` is also complete and seekable.

### HLS session coordinator

`HLS/Session.pm` owns network requests and stream state. It:

- reloads media playlists shortly before their target duration expires;
- deduplicates segments by playlist epoch and media sequence;
- skips the deduplication hash for complete VOD playlists, which cannot
  produce overlapping reload windows;
- bounds live-stream deduplication history to the current playlist window plus ten preceding media sequences;
- detects a media-sequence restart and resets extractor state;
- resets MPEG-TS and fragmented MP4 extraction state at HLS discontinuities and reloads MP4 initialization data;
- starts a live stream near the live edge by retaining only the final three initially visible segments;
- downloads up to three media segments concurrently and extracts them in
  playlist order;
- targets eight seconds of buffered live audio and thirty seconds for VODs,
  independently of the number of concurrent requests;
- downloads fragmented MP4 initialization segments when `EXT-X-MAP` changes;
- retries playlist, initialization and media-segment failures after three seconds;
- reads the exact AAC profile and sample rate from the first ADTS frame;
- supplies data through non-blocking reads to the LMS protocol adapter.

Playlist and segment HTTP requests use a twenty-second timeout. While a request is pending and no audio is available, the adapter reports `EWOULDBLOCK` on LMS versions with the corrected asynchronous I/O behavior and `EINTR` on older versions.

## Supported HLS media containers

### MPEG-TS with AAC

`HLS/Extractor/MPEGTSAAC.pm` reads 188-byte MPEG transport stream packets. It parses the program association table to locate the program map table, then finds the elementary stream declared as MPEG-4 AAC (`stream_type` `0x0f`).

For the selected audio PID, the extractor:

- removes transport packet and adaptation-field headers;
- removes PES headers at payload-unit boundaries;
- checks continuity counters for diagnostic logging;
- reassembles AAC payload across packet and segment boundaries;
- validates ADTS synchronization and frame lengths;
- emits complete ADTS frames only.

The AAC PID is cached after discovery. Continuity tracking is retained across
ordinary segment boundaries and reset together with the extractor at an HLS
discontinuity or playlist-sequence restart.

### Fragmented MP4 with AAC

`HLS/Extractor/MP4AAC.pm` supports fragmented MP4 playlists that provide an initialization segment through `EXT-X-MAP`.

The initialization parser locates the audio track in `moov/trak/mdia`, obtains its track ID, reads AAC `AudioSpecificConfig` from `esds`, and reads default sample sizes from `mvex/trex` when present.

For each media fragment, the extractor processes `moof/traf/tfhd/trun`, resolves sample locations and sizes, extracts AAC access units from the associated media data, and generates an ADTS header for every sample. The result is therefore the same ADTS-AAC stream format used by the MPEG-TS path.

An MP4-looking segment without `EXT-X-MAP` is rejected because the AAC codec configuration required to construct ADTS headers is unavailable.

## Live-stream behavior

Live streams deliberately use non-seekable semantics:

- no duration is exposed;
- no progress bar should be displayed by LMS skins;
- stale duration and start-offset values inherited from a previously played VOD are explicitly cleared;
- the LMS remote-stream clock is reset when live playback starts;
- the initial playlist begins close to the live edge;
- the playlist continues to reload until playback stops or Twitch ends the stream.

The media type is attached to the LMS song and is also derived from the logical or mapped HLS URL. Unknown streams default to live semantics so an uncertain classification cannot accidentally expose a duration.

## VOD behavior

VODs expose their Twitch total duration to LMS and support time-based seeking. LMS seek requests are translated to a target time in the HLS timeline.

The playlist parser selects the segment containing the requested time. After that segment is extracted, the session estimates the corresponding byte offset within its AAC payload from the requested fraction of the segment. Playback therefore resumes close to the requested position rather than at the beginning of the segment.

The progress offset and LMS remote-stream start time are updated after a seek so skins display the requested position instead of restarting the marker at zero.

### Standby resume

LMS may destroy both the active stream reader and its song instance while a player is in standby. To survive that lifecycle, the plugin tracks the latest delivered VOD position in two places:

- as plugin data on the current LMS song;
- in the LMS cache, keyed by player ID and Twitch VOD ID.

The cached resume entry is valid for one hour. When LMS creates a new stream reader after standby, the position is restored and used as the initial VOD seek time. Explicit user seeks update the same state, including an explicit seek to zero.

The tracked position represents audio delivered from the plugin to LMS. It is calculated from the segment start time, duration and current byte offset, so it is an estimate rather than a timestamp derived from individual AAC frames.

## Metadata and duration handling

Once a segment has been extracted, the plugin exposes the exact sample rate
from its ADTS header in the dedicated LMS `samplerate` field. It retains
`AAC (Twitch)` as the media type, allowing Material Skin to render the values
as `Twitch · AAC, 48 kHz`. It deliberately
does not expose a bit depth, because compressed AAC has no PCM bit-depth field,
or a single bitrate, because Twitch AAC may be variable-bitrate.

The detected audio properties are attached to the active LMS song and cached
under the logical Twitch media identity. This keeps the technical information
available when LMS asks with either the original `twitch:` URL or its resolved
HLS URL, including metadata calls which pass the song object explicitly.

Metadata includes:

- stream or VOD title;
- channel login as artist;
- channel profile image for live streams;
- VOD thumbnail for archived content;
- VOD duration only;
- AAC profile and sample rate read from the media stream.

Metadata is stored in LMS's cache for the configured cache lifetime and attached to the song as `wmaMeta`, which allows standard LMS metadata consumers and skins such as Material Skin to display it. Cached live metadata is applied immediately while a background request refreshes it. The first successful refresh of a new live playback synchronizes title, channel login and profile image. Later refreshes update only the mutable stream title, preserving the channel artist and cover. Successful live refreshes are limited by `live_cache_ttl`; failed refreshes may be retried after 30 seconds. The live refresh interval does not expire currently displayed metadata: cached or song-attached values remain available until fresh values replace them. VOD metadata continues to use the longer general cache lifetime.

Metadata resolution is URL-authoritative. The plugin first matches the requested URL to its Twitch media identity instead of blindly using `playingSong`. This prevents artwork, artist or VOD duration from leaking into another item during an asynchronous track transition.

When metadata changes, the plugin emits an LMS `newmetadata` notification. Cached metadata can therefore be restored after standby without waiting for another successful Twitch API request.

## Copyright-muted segments

Twitch identifies some muted VOD segments by names such as:

```text
3-muted.ts
3-muted.mp4
```

The playlist parser marks these segments as muted. The session does not download or decode them; it advances the internal timeline and emits no audio for their duration. Processing such a segment creates the following informational log entry:

```text
Audio for this section has been muted by Twitch because it contains copyrighted content.
```

The plugin does not attempt to recover, replace or bypass audio muted by Twitch.

## Configuration

The plugin initializes three LMS preferences in the `plugin.twitch` namespace:

| Preference | Default | Purpose |
| --- | ---: | --- |
| `client_id` | `kimne78kx3ncx6brgo4mv6wki5h1ko` | Client ID sent to Twitch GraphQL requests. |
| `cache_ttl` | `3600` | Lifetime in seconds for VOD metadata and media-URL associations. |
| `live_cache_ttl` | `300` | Refresh interval in seconds for live-channel metadata; retained values use `cache_ttl`. |

Invalid, empty or non-positive values fall back to their defaults. There is currently no dedicated settings page; preferences must be changed through LMS configuration mechanisms or by modifying the plugin defaults.

The VOD standby-resume cache has a fixed lifetime of 3,600 seconds.

## Logging

The plugin registers the LMS log category:

```text
plugin.twitch
```

Its default level is `ERROR`.

- `INFO` reports stream lifecycle events, VOD seeks and Twitch-muted sections.
- `DEBUG` reports playlist processing, resolved stream URLs, segment/container
  statistics with media sequence and MPEG-TS continuity-counter ranges, AAC
  PID discovery, continuity changes and stored resume positions.
- `ERROR` reports HTTP failures, invalid GraphQL or JSON responses, missing playback data, invalid playlists, unsupported MP4 initialization data, missing AAC streams and failed playlist or segment requests.

Resolved Twitch HLS URLs contain temporary playback credentials and are logged only at `DEBUG`. Debug logs should therefore be treated as potentially sensitive and should be sanitized before publication.

## Module layout

| Module | Responsibility |
| --- | --- |
| `Plugin.pm` | LMS application registration, channel search, menu construction and VOD browsing. |
| `Config.pm` | Plugin preference defaults and validation. |
| `API.pm` | Asynchronous Twitch GraphQL, playback-token and master-playlist requests. |
| `ProtocolHandler.pm` | Logical `twitch:` protocol, LMS scanning, URL identity mapping and initial metadata. |
| `HLSStream.pm` | LMS non-blocking stream adapter, duration/seek integration, metadata exposure and standby resume. |
| `HLS/Playlist.pm` | Pure HLS media-playlist parsing and timeline calculations. |
| `HLS/Session.pm` | Playlist reloads, requests, queueing, prefetch, retry logic and extractor coordination. |
| `HLS/Extractor/MPEGTSAAC.pm` | MPEG-TS demultiplexing and ADTS-AAC extraction. |
| `HLS/Extractor/MP4AAC.pm` | Fragmented MP4 parsing and conversion of AAC samples to ADTS frames. |

## Network endpoints

At runtime the plugin communicates with:

- `https://gql.twitch.tv/gql` for channel, VOD and playback-token data;
- `https://usher.ttvnw.net/` for Twitch live and VOD HLS master playlists;
- Twitch CDN URLs referenced by the selected audio-only media playlist.

All requests are asynchronous. The plugin does not operate a proxy service and does not send credentials to any server other than the Twitch endpoints contained in the playback flow.

## Limitations and compatibility notes

- Twitch's GraphQL schema, persisted query hashes, playback-token flow and HLS conventions are not a stable public plugin API. Twitch can change them without notice.
- Only the `audio_only` rendition is selected. The plugin does not download or transcode video.
- Output is always presented to LMS as AAC. No codec transcoding is performed.
- MPEG-TS support expects an AAC elementary stream declared as stream type `0x0f`.
- Fragmented MP4 support requires an `EXT-X-MAP` initialization segment and a supported AAC configuration in `esds`.
- Encrypted HLS segments and DRM-protected media are not implemented.
- Alternate audio groups, byte-range media segments and low-latency HLS partial segments are not explicitly implemented.
- Seeking within a segment uses a proportional byte estimate and may not be sample-accurate.
- Playback depends on the temporary signed Twitch URLs remaining valid for the active session.
- The plugin intentionally respects Twitch-muted copyrighted sections.

## Release process

Releases are produced by `.github/workflows/release.yml` through a manually triggered GitHub Actions workflow.

The workflow:

1. reads the version from `install.xml`;
2. skips publishing if that Git tag already exists;
3. creates `TWITCH.zip` from tracked files using `git archive`;
4. verifies that `install.xml` is included and lists all archive entries, including tracked plugin subdirectories;
5. excludes `.github/`, `repo/` and `.gitattributes` through export attributes;
6. calculates the ZIP SHA-1 checksum;
7. updates `repo/repo.xml` with version, checksum and release URL;
8. commits the repository metadata update;
9. creates the matching GitHub release and uploads `TWITCH.zip`.

The version in `install.xml` is the authoritative release version.

## Development notes

The codebase uses strict and warning-enabled Perl modules and relies on LMS's event-driven networking model. Network operations must remain asynchronous; blocking HTTP calls would stall the LMS server loop.

When changing playback behavior, test at least these transitions:

- cold start of a live stream;
- cold start of a VOD;
- VOD seek forward and backward;
- VOD to live without stopping the player first;
- live to VOD;
- standby and resume for live playback;
- standby and resume for VOD playback;
- MPEG-TS and fragmented MP4 playlists;
- muted `.ts` and `.mp4` segments;
- expired or failed Twitch requests.

Live and VOD classification must remain explicit. In particular, live tracks must never inherit the database duration, progress offset or metadata of a previously active VOD.

## Legal notice

Twitch is a trademark of Twitch Interactive, Inc. This project is an independent LMS plugin and is not affiliated with or endorsed by Twitch.

This plugin is designed solely and exclusively for **audio-only playback**. It explicitly requests Twitch's `audio_only` HLS rendition and processes only the AAC audio contained in that rendition. It does not select, download, decode, transcode, reconstruct, display or forward Twitch video content.

The plugin only processes unencrypted HLS media that Twitch makes available through its regular playback-token and playlist flow. The media accepted and handled by the plugin contains no DRM layer that the plugin must remove or bypass. The plugin contains no DRM implementation, decryption system, key-acquisition mechanism or code intended to defeat encryption, access controls, copy protection or any other technical protection measure. Encrypted or DRM-protected media is unsupported and is not processed.

No deceptive, exploitative or otherwise improper method is used to obtain media. The plugin requests the normal Twitch playback data, selects the audio-only rendition advertised by Twitch, downloads the referenced unencrypted audio segments and converts their existing AAC payload into the ADTS-AAC framing required by LMS players. This container-level conversion neither decrypts the content nor removes a protection mechanism.

The plugin also respects Twitch's copyright muting. Segments identified by Twitch as muted are skipped without attempting to recover, reconstruct or obtain the removed audio through another source.

Nothing in this notice should be read as a general claim that every service, stream or item offered by Twitch is necessarily free of DRM. It describes only the unencrypted audio-only HLS media accepted by this plugin and the behavior implemented in this repository.

Users are responsible for complying with Twitch's terms, the rights of content owners and all applicable laws in their jurisdiction.
