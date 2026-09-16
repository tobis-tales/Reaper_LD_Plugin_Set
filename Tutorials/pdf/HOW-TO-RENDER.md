# How the PDFs in this folder are rendered

The PDFs are not a second source. They are the HTML pages one folder up,
printed by headless Chrome through the print stylesheet in
`Tutorials/steelblue.css` (`@media print`: A4, 14 mm × 12 mm margins, brand
colours forced on, and no figure or step split across a page break). Edit the
HTML, render again — never edit a PDF.

`build-package.sh` copies these files into `Guides (PDF)/` inside the package
and leaves `Tutorials/pdf/` itself out, so the package ships the HTML guides
for reading on screen and the PDFs for printing and mailing.

## The command

macOS, with Google Chrome installed in the usual place. Run it from the repo
root:

```sh
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

for page in index live-bpm-analyzer midi-notes-to-project-markers \
            rename-selected-markers copy-markers steelblue-ld-tools; do
  "$CHROME" --headless --disable-gpu --no-sandbox \
    --no-pdf-header-footer \
    --print-to-pdf="Tutorials/pdf/$page.pdf" \
    "file://$PWD/Tutorials/$page.html"
done
```

On Windows or Linux the only thing that changes is `CHROME`
(`chrome.exe` / `google-chrome` / `chromium`); the flags are the same.

## Why these flags

| Flag | Why |
| --- | --- |
| `--headless` | No window. Chrome still lays the page out exactly as it would on screen. |
| `--disable-gpu --no-sandbox` | Headless Chrome on a machine with no display session; without them it can fail to start. |
| `--no-pdf-header-footer` | Otherwise every page carries Chrome's own date, title and `file://…` URL. On older Chrome builds this flag is `--print-to-pdf-no-header`. |
| `--print-to-pdf=…` | The output path. Chrome writes the file and exits. |
| `file://$PWD/…` | An absolute `file://` URL. A relative path is not a URL and Chrome will render an error page into the PDF instead of failing loudly. |

Paper size, margins and page breaks come from the stylesheet, not from the
command line — so the PDFs cannot drift away from what the browser shows.

## After rendering

- Check that every PDF is newer than its `.html` and that none of them is
  suspiciously small (a few hundred KB each is normal; the screenshots are
  most of the weight).
- `Tutorials/img/` holds the screenshots the pages embed. Re-render whenever a
  screenshot is replaced, not only when the text changes: the images are
  embedded in the PDF, so a new PNG on disk changes nothing until Chrome runs
  again.
