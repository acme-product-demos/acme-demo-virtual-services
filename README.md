# virtual-services

A repo-aggregator for standing up and updating many services' mocks from one
place — the pattern Shamasis described for the Guardian Life service-
virtualization conversation: check out every target service as a git
submodule, run one pipeline that regenerates each one's mock straight from
its current spec, smoke-test it, and push. Adding service N+1 to the fleet
is one more submodule and one more line in a lookup table, not a new
PR/review cycle per service.

This repo owns its own set of mocks — separate from each service's own
per-repo mock — representing the org-level "Virtual Services" UAT
environment, generated centrally rather than hand-maintained per team.

## Layout

```
services/<name>/          git submodule, one per backend service
postman/mocks/<name>/     the virtual mock generated from that submodule's spec
scripts/regenerate-mocks.sh   the pipeline: regenerate -> smoke-test
```

Workspace: **Virtual Services** (team visibility), bound via
`.postman/resources.yaml`.

## The pipeline

```bash
./scripts/regenerate-mocks.sh
```

For each submoduled service, this:

1. Runs `postman mock generate --update postman/mocks/<service>` — regenerates
   the mock in place from whatever's currently checked out in
   `services/<service>`'s spec. First-time creation for a new service looks
   like:
   ```bash
   postman mock generate services/<name>/postman/specs/<name>/index.yaml \
     --mode stateful -o postman/mocks/<name> -n "<Name> (Virtual)"
   postman mock push postman/mocks/<name> -w <workspaceId>
   postman mock deploy <mockId> --slug <name>-virtual -y
   ```
2. Starts the regenerated mock locally and smoke-tests one real read
   endpoint.
3. Only on success: the caller (CI, or you locally) commits whatever
   changed and `postman mock push`es it, which live-updates the already-
   deployed server.

To pick up a service's latest spec before regenerating:
```bash
git submodule update --remote --merge
```

## Why smoke-test, not a full collection run

This was the real finding from building this repo. `postman mock generate
--mode stateful` produces solid output for textbook flat CRUD — `GET` a
list, `GET`/`PUT` by id — but gets two other shapes wrong:

- **Non-CRUD "action" endpoints modeled as POST** (e.g. `POST
  /api/inventory/{id}/reserve`, `POST /api/cart/checkout`): the generator
  treats any POST as "create a new resource," so it returns a generic
  `{ ...echoedBody, id: <autoincrement> }` with a `201`, not the real
  resource with the status code the spec actually documents.
- **Nested array sub-resources** (`PUT /api/cart/items/{productId}`, where
  an item lives inside a parent cart rather than as its own top-level
  collection): confirmed to **hang the server outright** — a direct `curl`
  with a 5s timeout got no response at all. Reproduced twice, independent
  of this script.
- **Read-only resources with no create endpoint** fall back to a static
  example — but if the spec has no embedded `example:` on that response
  (only schema-level `example`s on individual properties), the generator
  synthesizes one by duplicating the single available item. For
  product-service this meant `GET /api/products` returned `[p1, p1]` —
  the same row twice — until an explicit 10-item `example:` array was
  added to the spec (see `services/product-service` history).

None of that is something this pipeline can paper over without hand-editing
generated code every run, which defeats the point of "regenerate straight
from spec." So validation here is a deliberately narrow, honest smoke test
— confirms the mock starts and serves real data on its primary read path —
rather than a full collection run that would fail or hang on generator
gaps, not on anything this pipeline is actually responsible for.

Each service's own repo still runs its full collection against its own
*hand-maintained* mock (see e.g. `cart-service/.github/workflows/postman-ci.yml`)
— that mock doesn't have these gaps, because it isn't produced by
`--mode stateful` generation.

## Adding a service

1. `git submodule add <repo-url> services/<name>`
2. First-time generate + push + deploy (see above)
3. Add `<name>` to `SERVICES`, and one line each to `port_for()` and
   `smoke_check()` in `scripts/regenerate-mocks.sh`
