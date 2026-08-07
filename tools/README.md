# convert_values_to_2_10.py

Utility to convert legacy NiFi Helm values files (2.8/2.9 style) into a 2.10-compatible format.

## What It Does

- Converts and normalizes deprecated keys and structures for 2.10.
- Reorganizes output into sectioned YAML blocks.
- Adds a conversion header with timestamp, source/output paths, and change counts.
- Prints a change report and warnings to stdout.
- Supports safe in-place conversion with automatic backup.

## Requirements

- Python 3.9+
- PyYAML

Install dependency:

```bash
python3 -m pip install pyyaml
```

## Usage

```bash
python3 tools/convert_values_to_2_10.py -i <input-values.yaml> [--inplace | -o <output-values.yaml>]
```

### Arguments

- `-i, --input` (required): input values YAML file
- `-o, --output`: output file path
- `--inplace`: overwrite input file in place (creates timestamped backup)

Notes:

- Use either `--inplace` or `--output` (not both).
- If neither is provided, output defaults to `<input>.2.10.yaml`.
- YAML comments/formatting from the original file are not preserved.

## Example Commands

Convert to a new output file:

```bash
python3 tools/convert_values_to_2_10.py \
  -i helm-content/tra-nifi/values-old.yaml \
  -o helm-content/tra-nifi/values-2.10.yaml
```

Convert in place (backup is auto-created):

```bash
python3 tools/convert_values_to_2_10.py \
  -i helm-content/tra-nifi/values.yaml \
  --inplace
```

Use the default output name (`.2.10.yaml`):

```bash
python3 tools/convert_values_to_2_10.py \
  -i helm-content/tra-nifi/values.yaml
```

Verify rendered chart after conversion:

```bash
helm template test helm-content/tra-nifi \
  -f helm-content/tra-nifi/values-2.10.yaml \
  --set labels.prefix=nifi.example.com \
  --set labels.appid=demo \
  --set labels.environment=e1 \
  --set labels.region=ipc1
```

## Common Migrations Performed

- `Logging` -> `clusterLogging`
- Removes deprecated top-level blocks: `hashicorp`, `ca`, `openldap`
- Normalizes secret modes:
  - `properties.secretsMode: file-dir` -> `directory`
  - `properties.secretsMode: file-single` -> `singlefile`
  - legacy `env` file secret modes -> `directory`
- Migrates Vault settings:
  - `VaultNiFiSecrets.secretProvider: traVaultSecrets` -> `vaultSidecar`
  - `VaultNiFiSecrets.traVaultSecrets` -> `VaultNiFiSecrets.vaultSidecar`
  - sets `VaultNiFiSecrets.vaultSidecar.image` if required
- Converts `NiFiSync.s3Sync.flowRestore.interval` (seconds/duration) -> `intervalMinutes`
- Consolidates legacy image keys into `images.nifi`, `images.utility`, `images.sidecar`
- Adds defaults for labels and selected fields when missing

## Backups

When using `--inplace`, backup files are created next to the input file:

- `<filename>.bak.<UTC_TIMESTAMP>`
- Example: `values.yaml.bak.20260722T204501Z`

## Troubleshooting

Missing PyYAML:

```bash
python3 -m pip install pyyaml
```

Input not found:

- Confirm path passed to `-i` exists.

Invalid flag combination:

- Do not combine `--inplace` and `-o`.
