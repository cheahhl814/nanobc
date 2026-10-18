# Dorado — models: download, selection, discovery (offline reference)

Source: https://software-docs.nanoporetech.com/dorado/latest/models/downloader/
and .../models/selection/ — captured 2026-10-18, condensed/attributed (ONT Public
License; full docs at those URLs and via `dorado download --help` /
`dorado basecaller --help` on the run host — verify flags there when this
capture is older than the binary).

## 1. Download (`dorado download`)

```
dorado download --model (<model_name>|all|<variant>) [--models-directory PATH]
                [--list|--list-yaml|--list-structured]
                [--data PATH_TO_POD5] [--recursive] [--overwrite] [-v]
```

- `--model <model_name>` — one model; `all` — everything; default is `all`.
- **`--models-directory PATH`** — download destination. **Default is the current
  working directory** — always pass this explicitly; nanobc's convention is
  `$NANOBC_HOME/assets/models/` (gitignored).
- **`--list` / `--list-yaml`** — enumerate available models *on this host*
  (simplex / modification model names, e.g. `dna_r10.4.1_e8.2_400bps_sup@v5.2.0`,
  `dna_r10.4.1_e8.2_400bps_hac@v6.0.0_6mA@v1`). Use this instead of a memorized
  catalogue — it always matches the installed Dorado version.
- **`--data pod5s/`** — auto-select the models matching the flow cell/chemistry
  found in the pod5 headers (`.fast5` NOT supported), e.g.
  `dorado download --model hac --data pod5s/`. `--recursive` scans subdirs.
- `--overwrite` — re-download over an existing model dir.

Model-name anatomy (simplex): `<readtype>_<chem>_<speed>@vX.Y.Z`, e.g.
`dna_r10.4.1_e8.2_400bps_sup@v5.2.0`; modification models:
`<simplex name>_<mod>@vZ`, e.g. `..._hac@v6.0.0_6mA@v1`.

## 2. Selection (`basecaller` / `duplex` model argument)

Three forms of the "model complex":

| Form | Meaning | Example |
|---|---|---|
| **Path** | use a downloaded model directory (no auto-download; must exist) | `dorado basecaller $NANOBC_HOME/assets/models/dna_r10.4.1_e8.2_400bps_sup@v5.2.0 pod5s/` |
| **Name** | full model name; found via model-discovery rules; auto-downloads if missing | `dorado basecaller dna_r10.4.1_e8.2_400bps_hac@v6.0.0 pod5s/` |
| **Variant** | `speed[version][,mod[version]]*` — data-dependent resolution | `hac`, `sup@v5.2,5mCG_5hmCG,6mA` (`@latest` is the default version) |

Variant rules: speeds `fast|hac|sup`; version `@vX.Y.Z` or `@latest` (default);
multiple modification models comma-separated, **one modification model per
canonical base at a time** (`sup,4mC_5mC,5mC_5hmCG_5hmC`-style conflicts are
invalid). Alternatives for mods: `--modified-bases` (space-separated codes,
resolves against the simplex model) and `--modified-bases-models`
(comma-separated names/paths).

## 3. Model discovery (when NOT selecting by path)

Search priority: (1) `--models-directory` CLI argument, (2)
`DORADO_MODELS_DIRECTORY` environment variable, (3) current working directory.

**Ephemeral auto-download warning**: with Name/Variant selection and neither
`--models-directory` nor `DORADO_MODELS_DIRECTORY` set, Dorado downloads the
model into a temporary location and **deletes it when the run finishes** — every
subsequent run re-downloads. Setting `--models-directory` (or the env var)
makes models persist and be reused.

## 4. How this maps onto nanobc

- nanobc pins **path-based** selection: `params.json:model` is a directory
  path passed to `dorado basecaller` — so the `basecaller` side never
  auto-downloads; models must exist on disk BEFORE the run (preflight §2c
  gates on this; the path's model dir is exactly what path-form selection
  expects).
- Recommended provisioning (preflight §2c/SP5):
  ```bash
  dorado download --list                                    # see what's available on this Dorado
  dorado download --model dna_r10.4.1_e8.2_400bps_sup@v5.2.0 \
      --models-directory "$NANOBC_HOME/assets/models"
  # then: params.json:model = $NANOBC_HOME/assets/models/dna_r10.4.1_e8.2_400bps_sup@v5.2.0
  ```
- If a future nanobc change adopts Name/Variant selection, ALWAYS set
  `--models-directory` or `DORADO_MODELS_DIRECTORY` (see the ephemeral-download
  warning above) — do not rely on cwd download.