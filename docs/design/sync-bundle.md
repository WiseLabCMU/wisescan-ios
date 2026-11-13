# Design: Sync the Whole Scan as One Bundle

**Status:** Built, device test pending (2026-11-11). Where the build departed from the plan, this
doc says what was built and why.
**Scope:** How a scan reaches the Scan4D server (the control plane in `scan4d-server`), what Share is,
and what goes away. It builds on [export-consolidation.md](export-consolidation.md), which made
Scan4D the one capture export.

## Today

Two paths reach the server, built separately and named differently:

- **Sync** sends each synced space's inventory as JSON, then map-package files one at a time
  ([scan4d-server README](https://github.com/WiseLabCMU/scan4d-server), "Map packages"). Small
  files go eagerly. The mesh, its colours, the proxy meshes and the world map go only when
  something asks: the web's 3D view, or a **Request** button. The phone learns of a request at
  its next sync, so the file arrives minutes or hours later, and only on Wi-Fi.
- **Upload** sends an export to `devices/<id>/exports/<format>/`, where the pipelines read it.
  It's a second copy of the same scan, under another name. A manual Upload URL is the fallback,
  and it is unauthenticated.

The map server never sees a photo.

## Decision

Two verbs, each with one meaning:

| | What | Where to | When |
|---|---|---|---|
| **Sync** | Everything: the map's JSON, a RoomPlan preview, and one bundle per scan | Your Scan4D server | Automatically, for the spaces you sync |
| **Share** | One file another system reads: Scan4D, OBJ, PLY, USDZ | The iOS share sheet (Files, AirDrop, Mail…) | When you tap Share |

**Removed:**
- the Upload button and the manual Upload URL;
- on-demand file requests, with the web's Request buttons;
- per-file uploads, except `roomplan.json`;
- the Send map packages setting.

The server keeps accepting the old per-file uploads and exports while older app builds are in
the field.

## What syncs

1. **The map's JSON.** This is today's sync manifest, sent whole on every sync: spaces, scans,
   registrations, links and fine-tunes, focus regions and tasks. Everything that changes after a
   capture travels here.
2. **The preview: `roomplan.json`.** Walls, floors and objects, a few KB per scan, uploaded once
   per version as today's eager files are. It gives the web a quick sense of the map before any
   bundle lands. It is the one exception to "files travel in the bundle", because its payoff is
   large and its size small.
3. **The bundle.** Everything else, one zip per scan. The server either holds a scan's current
   bundle, extracted, or it doesn't: that is the scan's whole file state.

The server's change evaluator reads the feature cloud and coverage grid, so it now waits for
the bundle, and with it for Wi-Fi. That's accepted.

## Which spaces sync

*(Added 2026-11-13, after field use: throwaway test scans were syncing.)* Two decisions, in
order. The first is which **spaces** sync; the second, below, which of their **bundles** go
(the pending checklist, the Wi-Fi rule, the Privacy Filter hold-back).

The first follows the familiar selective-sync pattern (a cloud drive's "choose folders to
sync"):

- **Each space has a switch**, Sync to Scan4D Server: on its screen, and in the Server tab's
  Spaces list (Choose spaces, with Turn All On for a backlog). It replaces the one-way Sync button
  and Auto sync's All / New / Off, under which a space, once synced, could never stop.
- **Off keeps a space on this device.** It is never reported, whatever the default. One that had
  synced is marked gone on the server, which keeps what it has: there is no server-side removal
  yet. That wants per-user and per-group access first, and the files are easy to clean on the
  server's file system meanwhile. A bundle of it under way stops.
- **A new space is decided where its maker knows it is a test**: the naming prompt after a capture.
  With a server set it has two saves, Save and Save on This Device (or Save and Sync when new
  spaces don't sync). The map's JSON leaves seconds after a save, so a later choice would come
  too late for the JSON, though not for the bundle.
- **Sync new spaces** (the Server tab, on by default) sets which save is the default, and whether
  a new space no prompt named (a Connect Adjacent space) syncs. It carries over Auto sync: Off
  stays off. Spaces from before the phone joined wait for their switch.
- **Sync on a stitched map, or on spaces selected in the Scans tab**, turns them on.

## The bundle

**Contents: everything.**
- **Room scan:**
  - the Scan4D export: frames, stills, depth, confidence, `cameras/`, the coloured mesh and its
    face classes, RoomPlan, registration, feature cloud, coverage, stitching, and the 360°
    stills with their cube faces and masks;
  - plus what map packages hold and the export doesn't: `arworldmap.map`, `colors.bin`,
    `mesh_proxy.obj` and `mesh_dynamic.obj`.
- **Focus scan:** the still-capture folder its export already is.

The bundle, the Scan4D export and Share's Scan4D file are one definition. It is always built
through the export's staging, so the privacy passes always run.

**Portable maps.** The world map in the bundle is the starting point for loading a map on
another device, so a map isn't tied to the phone that made it. That works at least within a
device class; across classes is being tested. The loading side is built separately.

**When it goes.** A scan's bundle is offered once the scan is settled: processed, and coloured
(Save and Upload already wait for processing; exports colour the scan first). After that,
changes to registration, links and focus regions travel in the JSON. Any other change to a file
in the bundle (a recolour, say) makes a new version, and the whole bundle goes again.

**Versions.** The phone fingerprints the bundle's source files (names, sizes, modification
times) without building it, and the manifest reports the fingerprint per scan. The server
answers with the state of each scan's bundle:
- none;
- uploading, or ingesting;
- current;
- stale: it holds an older version.

**Format.** The Scan4D export's own zip, its entries under one top folder, which the server
strips. *(Planned: a stored zip from a revived writer. Built: the export's zip as it is, which is
proven in the field and keeps one way of packing; storing instead is an optimisation for later.)*

**Size.** Hundreds of MB for a room scan, 1–3 GB with 360° stills, in one PUT. A resumable or
multipart upload comes if failures on large bundles show it is needed.

## On the phone

- **Build at send time** into the Caches folder.
- **Keep the built bundle until:**
  - the server reports it current, or
  - its scan's fingerprint changes, or
  - a timeout passes (7 days).

  So a failed upload retries without rebuilding; the old Upload re-zipped on every failure. iOS
  may purge Caches under storage pressure, which only means a rebuild.
- **Upload in a background URLSession** from the file, so it continues while the app is
  suspended.
- **Never built beside other heavy work.** Building runs the export's privacy passes. A capture
  starting, or a Share export starting, stops a build under way (its loops check a stop token,
  and a stopped build zips nothing), and it starts again when that ends. A bundle never starts
  while a Share builds, so two privacy passes never run at once (the OOM class behind Share's
  in-flight guard). A bundle's coloring can't stop midway, so a Share waits for it.
- **Never a torn copy.** Process and Color rewrite a scan's files. A build doesn't start while
  either holds the scan or its steps are due, and a build whose files changed while it ran is
  dropped and tried again a minute later.
- **Its own file.** A bundle builds under its own name, so a sync and a Share of the same scan
  never touch each other's zip.
- **Upload data bundles only on Wi-Fi** is a setting, on by default. The JSON and the preview go
  on any network. Turning it on stops an upload that may be on cellular, whatever its progress,
  and sends it again from the cache under the rule.
- **The pending checklist** lists each scan whose bundle the server lacks, with its space, size
  and state, all selected by default. Deselected scans wait until selected again, and
  deselecting one being sent stops it. New scans join selected. The checklist replaces today's
  "N waiting for Wi-Fi" count, and with it the worry about flooding the
  server with a backlog. *(Added in review: a scan captured with the Privacy Filter off starts
  deselected, since its photos show people unblurred, and a phone that had Send map packages off
  starts with every scan it held deselected, since bundles carry far more than packages did.)*
- **The Server tab.** *(Added after review: the checklist first lived in Settings, where nothing
  on a scan led to it.)* The app's fourth tab holds the Scan4D server in one place: the last sync's
  status with Sync now, the checklist inline with the Wi-Fi rule, and the connection settings that
  were in Settings. Its icon counts the bundles waiting for Retry. A card whose bundle the checklist
  holds back offers Select on its sync line, and selecting a scan captured with the Privacy Filter
  off asks first, with Always Send to stop asking (undone by the tab's Ask before sending unblurred
  scans). Pulling maps down from the server belongs here when it comes.
- **Uncoloured scans.** A scan offers its version once processed. The uploader colours it, if it
  can, just before building, and sends the coloured version, so a scan the app can't colour
  still syncs.
- **Failures.** A failed upload tries again from the cache, after 15 minutes, then twice as long
  after each failure in a row, up to 6 hours. Refusals that sending again can't change (uploads
  revoked for the device, a scan the server doesn't know, a bundle over its size limit) aren't
  retried until the scan's version changes or the user taps **Retry**. Neither is a bundle the
  server couldn't unpack (`failed`): Retry builds it afresh, so a broken bundle can't cost
  gigabytes every few minutes.
- **The version, cheaply.** A scan's version covers only what the export reads, so caches the app
  regenerates don't make a new one. It is re-read in full only when a quick look at those files
  and folders changes, or once an hour. A build reads it afresh, and if that differs from what
  the server saw, it syncs first so the server wants the new version.
- **One server's state.** Which spaces the server confirmed, and every bundle's state, belong to
  the server they came from. A sync that reaches another server starts them afresh. The
  checklist's choices and built bundles stay.

## The sync indicator

The cloud badge on a space (its tile and its graph tile) shows how much of the space the server
holds. Today it shows exports uploaded: none, some or all. Share needs no indicator.

| Badge | State | Meaning |
|---|---|---|
| none | Off | The space isn't synced, or no server is set. |
| outline cloud (`icloud`) | Map | The server has the space's JSON and RoomPlan preview, but not every scan's current bundle. |
| green check cloud (`checkmark.icloud.fill`) | Everything | Every scan's current bundle is extracted on the server. |

- **Partial is Map.** A space with three of five bundles up shows Map; "3 of 5" is in the
  space's detail and the checklist. The badge never claims more than is there.
- **Server-confirmed only.** Map means a sync that included the space succeeded. Everything
  means the server reported each bundle current, so extracted, not just uploaded. The old
  `lastUploadedAt` (exports sent to `exports/`) doesn't carry over; the first sync after the
  update fills in the real state.
- **Temporary states replace the icon while they last:**
  - uploading or ingesting: `icloud.and.arrow.up`, with progress on the scan card;
  - failed: `exclamationmark.icloud`, yellow, with the reason on the card;
  - waiting for Wi-Fi or deselected in the checklist: plain Map; the checklist says why.
- **A changed scan drops back.** A scan that changes after its bundle went is Map until the new
  version is current, and so is its space.
- **The scan card** shows one line in place of "Uploaded <date>": Map only, Everything · <date>,
  Uploading 40%, Waiting for Wi-Fi, or Not selected. The export status pill goes.
- **One view draws the badge** for the space tile and the graph tile; today each has its own
  copy (`ScansListView.swift`, `StitchGraphView.swift`).

## On the server

1. **Upload.** The phone streams the zip to `PUT /v1/scans/{id}/bundle` with its fingerprint in
   `X-Scan4D-Bundle-Fingerprint`, under the server password and the per-device revocation. It
   lands as `<map>/.incoming/<scan>.<fingerprint>.zip`, and the ingest job is queued in the
   transaction that records it. *(Planned: an S3 grant, then a completion report. Built: a PUT
   to the API, as map-package files already went. That needs no bucket configured and no
   round trips, and the server knows the upload is whole the moment the body ends.)*
2. **Ingest**, by a job queue in Postgres, with no new service:
   - **The queue.** A jobs table with status, attempts and error. One worker in the API process
     claims jobs (`SELECT … FOR UPDATE SKIP LOCKED`, so more workers stay safe) and runs one at
     a time, in a thread, off the event loop. At startup, jobs left running go back to queued.
     Evaluations and webhook delivery, which today are fire-and-forget background tasks, can
     move onto the same table later.
   - **Extraction.** It goes into a hidden folder beside `<scan>/`, then that folder is swapped
     in as `<scan>/` and the zip deleted. A rerun does no harm.
   - **Checks.** Every entry stays under the root, with no links and no absolute paths. Sizes
     are capped, and there must be free space for the whole bundle.
   - **The event.** It emits `bundle.ingested`.
3. **Readers.** The extracted files keep today's names and place (`mesh.obj`, `colors.bin`,
   `arkit_features.bin`, …), so the 3D view and the change evaluator read them as they do now.
   The flows read the same folder: `scan4d-normalize` takes it as it is. `bundle.ingested` is
   where an automatic `scan4d-splat` run hangs later.

`exports/` keeps the uploads already there; the app sends nothing new to it.

## Share

Share asks for a format each time and hands it to the share sheet: the Scan4D bundle as a
file, or OBJ, PLY or USDZ. There is no stored format setting. Nerfstudio and
flame3d layouts come from a converter script, so everyone still gets the superset by default.
That script lives in the public app repo (`tools/`): `normalize.py` moves there from
scan4d-flows and becomes the original, next to the flame3d converter, and the flows copy both,
as `scan4d-priors` copies its tools. That keeps one implementation rather than a server one and
a public one drifting apart. On the server, `scan4d-convert` makes the same two layouts.

## Photos on the map

With `images/`, `cameras/` and `registration.json` on the server, the web can draw each photo's
camera in the map's canonical frame and open the photo on a click. Photos are more sensitive than
meshes, so once there is more than one login, they need the same per-user access checks as the
Files page.

## Phases

1. **Server:**
   - the jobs table and worker;
   - bundle upload and ingest;
   - bundle state in the sync response;
   - the README's Sync and Map packages sections rewritten to match.
2. **App:**
   - build, cache and upload the bundle, with its fingerprint in the manifest;
   - the checklist and the Wi-Fi setting;
   - the sync badge (Off, Map, Everything) and the scan card's sync line;
   - remove Upload, the Upload URL and on-demand files;
   - the Share sheet.
3. **Tools:** the converter script, with `normalize.py` moved to its new home.
4. **Web:**
   - bundle state on the map page, in place of per-file state and Request buttons;
   - photos on the map.
5. **Flows:** read scan folders, and start on `bundle.ingested`.

## Open

- Whether large bundles need multipart upload.
- The cache timeout: 7 days to start.
- Photo access control, once there is more than one login.
- Portable maps: loading another device's world map, built separately.
