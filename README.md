# T2170 Print

An iPad app that drives an Epson SureColor T2170 over IPP, with the same panes and
options as the Mac driver. The app imposes and rasterises pages itself (N-up, fit to
roll, banner, poster, colour controls) and sends the printer a finished PDF, so the
printer only has to load the right media and print the sheets as they arrive.

Status: compiles and passes its unit tests, **not yet tried against the printer.**
See "What needs the printer" below before the first real job.

This is an independent project, not affiliated with or endorsed by Epson. Epson and
SureColor are trademarks of Seiko Epson Corporation.

## Layout

| Path | What it is |
|---|---|
| `T2170Print/Model/PrintSettings.swift` | The Mac driver's options that do something on this path; panel-only ones were removed. The contract the other layers build on; change with care. |
| `T2170Print/UI/` | SwiftUI panes (Basic, Layout, Paper Handling, Colour Matching, Advanced, Preview, Printer) and `PrintSession`, the observable that owns the document, the printer client and the print flow. |
| `T2170Print/IPP/` | IPP 2.0 wire codec (`IPPMessage`), client actor (`IPPClient`), capability parser (`PrinterCapabilities`), Bonjour discovery (`PrinterDiscovery`), and `JobAttributesBuilder` (settings to job attributes). `RawSocketTransport` (port 9100) is present but unused. |
| `T2170Print/Render/` | `PageSource` (PDF/image loading), `Imposer` (settings to sheet plans), `SheetComposer` (plans to PDF or preview images), `ColorPipeline` (Core Image colour controls). |
| `T2170PrintTests/` | Swift Testing suites: settings, IPP codec, attribute builder, imposition, colour, raster encoders, readiness checks and band slicing. Runs anywhere. `SimulatedPrinterTests` and `FailureTests` need the daemons below and switch on by environment variable. |
| `tools/` | `fake_ipp.py` (scripted misbehaving printer), `check_spool.py` and `decode_raster.py` (inspect what was sent). |
| `project.yml` | xcodegen spec. `xcodegen generate` rebuilds the `.xcodeproj`. |
| `build.sh`, `test.sh` | Compile check and simulator test run; `farm/compile.jobs` lists both as jobs for a build farm. |

## Build and test

```sh
xcodegen generate
./build.sh          # compile for generic iOS, no signing
./test.sh           # unit tests on an iPad simulator
```

`./test-sim.sh --ppd <t2170.ppd> --refs <dir>` adds the whole print flow against
`ippeveprinter` and `tools/fake_ipp.py`. Both are models written from the PPD and the IPP
specs, so a pass says the app behaves against those models, not that a T2170 will agree.
Epson's PPD stays out of the repo; take it from the Mac driver DMG.

Logs land in `build/farm/compile.log` and `build/farm/test.log`; the real test count is
the Swift Testing line (`Test run with N tests`), not XCTest's "Executed 0 tests".

## How a print happens

1. `PrintSession.loadDocument` opens the PDF or image (security-scoped access is held for
   the document's life because `PDFDocument(url:)` reads lazily).
2. `Imposer.plan` turns the settings and page sizes into `SheetPlan`s; `SheetComposer`
   renders them to preview images or to a PDF for printing.
3. `JobAttributesBuilder` maps the settings to IPP job attributes, gated by the
   capabilities read from `Get-Printer-Attributes`. The media size sent is the composed
   sheet's size, `number-up` is 1 and `print-scaling` is `none`, because the pages
   arrive final. Anything the printer doesn't list is dropped and shown in the Printer
   pane as "dropped".
4. `Validate-Job`, then `Print-Job`, then `Get-Job-Attributes` polling until the job is
   completed, canceled or aborted. Printer-reported unsupported attributes are merged
   into the same "dropped" list.

## What needs the printer

None of this has run against a T2170 yet. First session with the printer, in order:

1. **Document format.** The app reads `document-format-supported` and sends `image/urf`,
   then `image/pwg-raster`, then `application/pdf`, whichever the printer lists first;
   "Send as" in the Printer pane overrides that. The Mac driver never sends PDF to the
   printer (CUPS converts it to ESC/P), so which of these the T2170 takes is only known
   from the printer itself. Note what it lists and which one printed correctly.
2. **IPP version.** The client starts at 2.0 and drops to 1.1 by itself if the printer
   refuses the version on connect. Note which one it settled on.
3. **Roll media keywords.** Roll widths and media types now match the Epson PPD (17
   widths, 25 types), but the PPD has no IPP keywords: its codes are ESC/P values
   (`EPIJ_FdSo`: 16 Roll, 0 Auto Sheet Feeder, 1 Sheet). So `media-source`
   `roll-1`/`auto`/`manual` and the `media-type` keywords are still guesses, `auto` for
   the sheet feeder most of all. Read `media-col-database` and `media-source-supported`
   from the report made by Capture Printer Details in the Printer pane and correct them. Confirm whether roll entries use a
   `rangeOfInteger` y-dimension (variable length) or fixed sizes.
4. **Auto-cut.** The app sends the first of `finishings` 11, 60, 62, 61, 63 that the
   printer lists, or reports `finishings` as dropped if it lists none. Check that the
   T2170 actually cuts. The Mac driver has no vendor attribute to fall back on.
5. **Printer-side Epson options: closed, none exist over IPP.** The Mac driver (v13.26,
   PPD `EPSON SC-T2100 Series`) sends every `EPIJ_*` option through `epsonpdftoescp` as
   ESC/P, with empty PPD invocation strings, so there are no vendor keywords to send.
   Density, colour controls, save roll paper and page line are done client-side; High
   Speed was removed. Reaching the rest would mean emitting ESC/P, which is out of scope.
6. **Substitution reporting.** On status `successful-ok-ignored-or-substituted-attributes`
   (0x0001) the app shows the unsupported group; confirm the T2170 actually sends it.
7. **ipps.** Only `ipp://` has a code path; `ipps://` with a self-signed certificate will
   fail trust in `URLSession.shared`. Connect over `ipp://` for now, or add a trust
   delegate pinned to the selected host.
8. **Marker levels.** Markers with negative `marker-levels` (the -1/-2/-3 sentinels) are
   hidden; check which sentinel the T2170 uses and that the ink names map to the right slots.
9. **Double-application check.** Print a 2-up landscape job and confirm the printer does
   not rotate or scale a second time (`print-scaling=none`, `number-up=1`).
10. **Margins.** Roll jobs keep a fixed 3 mm side margin (the PPD gives 2.96 mm). Print a
    full-bleed test on roll and check nothing is clipped. Save Roll Paper keeps 0 mm top and
    bottom: check that too.
11. **Roll check.** Before each job the app compares the Roll Width setting with
    `media-col-ready` and refuses on a mismatch. A roll width off the app's list, or a
    printer that does not report one, goes ahead with no width check at all. Note what the
    T2170 reports.
12. **Custom roll lengths.** A roll job's length is usually not on the printer's size list.
    If the printer refuses `media-col` for a raster roll job, the app resends it without
    `media-col` and says so under Last job: the size then comes from the page header alone,
    and the paper source isn't named. Sheet jobs and PDF are refused instead. The PPD allows
    custom sizes up to 1746 x 51840 pt, but ippeveprinter doesn't carry that over, so the
    simulator can't show which path the T2170 takes. Print a roll job and note whether that
    message appears and whether the job came out on the roll at the right size.

## Known limits (not blocked on hardware)

- Preview renders are cancelled between slider drags; a running render stops at its
  next sheet boundary and returns a shorter array. A debounce is the fix if it feels laggy.
- Rasters are capped at 40 megapixels per slice. A PDF page with colour adjustment on is
  rendered band by band, so a long roll keeps full resolution; up to half a source pixel of
  shift at the last band seam is accepted.
- Printing runs in the foreground only: leaving the app during a job can end it.
- Jobs go as a single Print-Job, so there is no job id, and no cancel, until the upload ends.
- The raster spool is copied once to make the request body, so a job needs twice its size in
  free space. The app checks before it starts and refuses if the space is not there. Large
  photographic rolls can need many GB.
- `RawSocketTransport` is not used by the app (URLSession carries IPP); it is not
  reentrant and does not recover a dead connection.
- `ipps` with a self-signed printer certificate is not trusted; use `ipp` or install the
  certificate on the iPad. A printer advertising both `_ipp` and `_ipps` appears twice
  in the discovery list.
- Attribute values of an unexpected length are tolerated, but a truncated response still
  fails as a whole.
- The Colour Matching pane and the Basic pane's `selectTarget` picker are stored but read
  by no IPP or render code: they do nothing yet.
- The vector draw path (unadjusted PDF pages drawn straight into the sheet) is covered by
  the simulated PDF scenarios only.
- A document with mixed sheet sizes goes out as one job per media size.
- Banner mode ignores pages-per-sheet and auto-rotate; poster overlap is approximate when
  the page aspect differs from the sheet.
- PDF pages are placed by their media box, not crop box.
- `media-size-name` is never sent (custom `media-col` size only); some firmware matches
  by name.
