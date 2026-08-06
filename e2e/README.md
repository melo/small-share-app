# e2e — the browser suite

Playwright driving a real Chromium against a real instance.

```
./run.sh              # everything: build, start, test, tear down
HEADED=1 ./run.sh     # watch it happen
KEEP=1 ./run.sh       # leave the instance up afterwards to poke at
./run.sh --ui         # extra args go straight to playwright
```

Or `make e2e` from the repository root.

## What is in here, and what is not

Everything in `tests/` is something HTTP alone cannot answer. If an assertion
could be made with curl it belongs in `app/t/share.t` instead — that suite is
faster and runs inside the image build. What is left is the part that needs a
real engine:

- **mermaid actually drawing an SVG**, inside a sandboxed iframe, under a CSP
  that names an explicit origin. This is the assertion the suite exists for:
  `'self'` matches nothing in the opaque origin a sandboxed iframe gets, so the
  policy spells the host out, and only a browser proves that was right.
- the drop zone accepting files, and the progress bar clearing when it lands
- `navigator.clipboard` actually receiving the URL when Copy is clicked
- `localStorage` history surviving a reload, newest first
- the viewer's header-over-frame layout having real, non-zero geometry
- a rejected file's message taking the full width of its row — the exact CSS
  bug that was reported, now pinned

## It never touches production

`share.<tailnet>.ts.net` holds other people's files. This suite uploads and
deletes freely, so it gets a **throwaway instance**: its own container, its own
port, an empty volume, torn down at the end. `run.sh` builds it from the
repository root, so it tests the code in the working tree rather than whatever
is deployed.

There is no local docker in the dev container, so by default `run.sh` builds and
runs the instance on `beebop` and reaches it through an SSH tunnel on
`127.0.0.1:8099`. With docker present locally it uses that instead. Either way
`SHARE_BASE_URL` is set to the tunnel address, so every URL the app hands out is
one the browser can actually follow.

Even so, the suite deletes only the ids it created, by id, in `afterAll`. No
sweeps — see the memory of what a sweep cost once.

## Not in CI

Deliberately. It needs docker, a browser and an SSH target, and the image build
already runs the unit suite with a 90% coverage floor. This is the pass you make
by hand when the front end changes.
