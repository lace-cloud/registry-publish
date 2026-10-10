# Lace Registry Publish

A GitHub Action that publishes the [Lace](https://lace.cloud) registry modules,
scanners, handlers and agents a push changed. It is published from the Lace
monorepo; changes are made there, not here.

Add `.github/workflows/publish.yml` to the repository that holds your
artifacts:

```yaml
# .github/workflows/publish.yml
name: publish
on:
  push:
    branches: [main]
permissions:
  contents: read
  id-token: write
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: lace-cloud/registry-publish@v1
        with:
          token: ${{ secrets.LACE_TOKEN }}
```

Pair it with [`lace-cloud/registry-check`](https://github.com/lace-cloud/registry-check)
on pull requests.

## The token

`LACE_TOKEN` is a Lace service token. Mint it in the Lace portal and store it
as a repository secret named `LACE_TOKEN`. When you mint it, name this
repository and the branch `publish.yml` runs on: a publish from any other
repository or branch is refused. The token's scope picks where the artifacts
go:

| Scope | Destination |
|---|---|
| `registry:publish:org` | your organization's private registry |
| `registry:publish` | the public registry, under your organization's own slug (each manifest's `author` is that slug) |

Any organization publishes from its own repository with these same two files.

## What it does

For each file the push changed, the action walks up to the nearest
`manifest.yaml` and publishes that directory with `lace registry register`. A
module is validated first and registered with its tree; the other axes are
registered by their manifest. A module is validated as its publication: the
registry view its children resolve against is the one the publish checks, so a
public module's children must be public, and validate refuses, naming the
child, before anything is published. A `README.md` beside the manifest is published
with it. Publishing unchanged content reports `unchanged`, so a re-run is safe.

Every changed manifest is tried. A refusal is recorded, the action goes on to
the next manifest, and the step fails at the end naming each refused one. The
job summary holds a table of every manifest, its axis and its result.

A push that creates a branch publishes every manifest in the repository.

## Inputs

| Input | Default | |
|---|---|---|
| `token` | required | The Lace service token. |
| `api-url` | `https://lace.cloud` | The Lace API to publish to. |
| `lace-version` | the release this version of the action was published with | The `lace` release to publish with, as `vX.Y.Z`. |
| `path` | empty | One manifest directory to publish instead of the changed ones. |

To republish one directory by hand, trigger the workflow with
`workflow_dispatch` and pass the directory as `path`:

```yaml
on:
  workflow_dispatch:
    inputs:
      path:
        description: The manifest directory to publish
        required: true
# ...
      - uses: lace-cloud/registry-publish@v1
        with:
          token: ${{ secrets.LACE_TOKEN }}
          path: ${{ inputs.path }}
```

## Requirements

- The action runs on `push` or `workflow_dispatch` and refuses every other
  event. A `pull_request` token cannot publish by design.
- `id-token: write`: every publish, on every axis, is verified by the GitHub
  OIDC token of the job that runs it.
- The checkout is the commit that triggered the run. The action refuses a
  checkout with `ref:` set to another commit, because the tree it would
  publish is not the tree the run's identity names. It fetches the commit the
  push started from itself, so the default shallow checkout is enough; leave
  `persist-credentials` at its default so it can.
- No `concurrency:` group. Each push publishes the directories between its own
  `before` and `after` commits, so overlapping runs publish disjoint sets and
  registering is idempotent; a group would cancel or queue a run whose
  directories no later run covers.
- `curl` on the runner. `ubuntu-latest` has it; a `container:` job needs it in
  the image. The action installs `minisign` with `apt-get` when
  the runner lacks it, using `sudo` unless the job already runs as root.

## Versions

`v1` moves to the newest `v1.N` release; `v1.N` never changes. Each `v1.N`
installs the `lace` release that was current when it was published, after
verifying the installer's signature under Lace's release-signing key. Pin
`@v1.N` to hold a release still, or pass `lace-version` to hold the CLI alone.

## License

[BUSL-1.1](./LICENSE)
