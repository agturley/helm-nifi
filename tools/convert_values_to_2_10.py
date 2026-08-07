#!/usr/bin/env python3
"""Convert NiFi Helm values files from 2.8/2.9 format to 2.10-compatible format.

Usage:
  python tools/convert_values_to_2_10.py -i old-values.yaml -o values-2.10.yaml
  python tools/convert_values_to_2_10.py -i old-values.yaml --inplace

Notes:
- Requires PyYAML (`pip install pyyaml`).
- Formatting/comments are not preserved (YAML is parsed and re-emitted).
"""

from __future__ import annotations

import argparse
import math
import re
import sys
from datetime import datetime, timezone
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

try:
    import yaml
except Exception as exc:  # noqa: BLE001
    print("Missing dependency: pyyaml. Install with: pip install pyyaml", file=sys.stderr)
    raise SystemExit(1) from exc




# Section ordering and grouping for organized YAML output
SECTION_ORDER = [
    ("BASIC DEPLOYMENT CONFIGURATION", ["replicaCount", "fullnameOverride", "sts"]),
    ("IMAGE & REGISTRY", ["images", "global"]),
    ("KUBERNETES CLUSTER & LABELS", ["labels", "caSecrets"]),
    ("KUBERNETES RESOURCES & SCHEDULING", ["resources", "affinity", "nodeSelector", "tolerations", "logresources", "zookeeperInit", "zookeeperResources", "syncresources", "extraContainerResources"]),
    ("JVM CONFIGURATION", ["jvm", "jvmMemory"]),    
    ("SECURITY & AUTHENTICATION", ["securityContext", "auth"]),
    ("NIFI PROPERTIES & CONFIGURATION", ["properties"]),
    ("LOGGING", ["clusterLogging", "logging"]),
    ("SECRETS MANAGEMENT", ["VaultNiFiSecrets", "awsSecretsSync"]),
    ("NIFI SYNC (S3, USERPOLICY, VAULT)", ["NiFiSync"]),
    ("NETWORKING & INGRESS", ["headless", "service", "ingress", "containerPorts"]),
    ("STORAGE & PERSISTENCE", ["persistence"]),
    ("CERT-MANAGER & TLS", ["certManager"]),
    ("ADVANCED & EXTRA OPTIONS", ["extraOptions", "extraVolumes", "extraVolumeMounts", "extraContainers", "initContainers", "env", "envFrom", "postStart", "terminationGracePeriodSeconds", "openshift"]),
]


def _reorganize_values_with_sections(values: dict[str, Any]) -> str:
    """Reorganize values dict into sections and format as YAML with section headers."""
    lines = []
    used_keys = set()

    for section_name, keys in SECTION_ORDER:
        section_entries = {}
        for key in keys:
            if key in values:
                section_entries[key] = values[key]
                used_keys.add(key)

        if not section_entries:
            continue

        # Add section header
        lines.append("")
        lines.append("# " + "=" * 77)
        lines.append(f"# {section_name}")
        lines.append("# " + "=" * 77)

        # Dump this section's entries to YAML
        section_yaml = yaml.safe_dump(
            section_entries,
            sort_keys=False,
            default_flow_style=False,
            allow_unicode=False,
        )
        lines.append(section_yaml.rstrip())

    # Add any remaining keys not in SECTION_ORDER
    remaining_keys = {k: v for k, v in values.items() if k not in used_keys}
    if remaining_keys:
        lines.append("")
        lines.append("# " + "=" * 77)
        lines.append("# OTHER SETTINGS")
        lines.append("# " + "=" * 77)
        remaining_yaml = yaml.safe_dump(
            remaining_keys,
            sort_keys=False,
            default_flow_style=False,
            allow_unicode=False,
        )
        lines.append(remaining_yaml.rstrip())

    return "\n".join(lines) + "\n"


@dataclass
class ConversionReport:
    changes: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    def add_change(self, msg: str) -> None:
        self.changes.append(msg)

    def add_warning(self, msg: str) -> None:
        self.warnings.append(msg)


def _as_dict(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _as_list(value: Any) -> list[Any]:
    return value if isinstance(value, list) else []


def _to_bool(value: Any, default: bool = False) -> bool:
    """Best-effort conversion of scalar values to bool."""
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"1", "true", "yes", "y", "on"}:
            return True
        if normalized in {"0", "false", "no", "n", "off"}:
            return False
    return default


def _split_image_ref(image_ref: str) -> tuple[str, str]:
    """Split a container image reference into repository and tag.

    Handles registry ports by only treating ':' after the last '/' as the tag delimiter.
    """
    if not image_ref:
        return "", ""

    # Ignore digest if present; this converter standardizes on repo:tag form.
    image_ref = image_ref.split("@", 1)[0]
    last_slash = image_ref.rfind("/")
    last_colon = image_ref.rfind(":")
    if last_colon > last_slash:
        return image_ref[:last_colon], image_ref[last_colon + 1 :]
    return image_ref, ""


def _normalize_image_map(image_map: dict[str, Any]) -> dict[str, Any]:
    """Drop empty-string fields (notably tag) from image config maps."""
    normalized: dict[str, Any] = {}
    for key, value in image_map.items():
        if isinstance(value, str) and value.strip() == "":
            continue
        normalized[key] = value
    return normalized


def _parse_old_flow_restore_interval_to_minutes(value: Any) -> int:
    """Convert legacy flowRestore.interval value to integer minutes.

    Old key was documented as seconds. We accept numeric and simple duration strings:
      30        -> 1
      "30"      -> 1
      "90s"     -> 2
      "2m"      -> 2
      "1h"      -> 60
      "1d"      -> 1440
    """
    if isinstance(value, (int, float)):
        seconds = int(value)
        return max(1, math.ceil(seconds / 60))

    if isinstance(value, str):
        s = value.strip().lower()
        if s.isdigit():
            seconds = int(s)
            return max(1, math.ceil(seconds / 60))

        m = re.fullmatch(r"(\d+)\s*([smhd])", s)
        if m:
            qty = int(m.group(1))
            unit = m.group(2)
            if unit == "s":
                return max(1, math.ceil(qty / 60))
            if unit == "m":
                return max(1, qty)
            if unit == "h":
                return max(1, qty * 60)
            if unit == "d":
                return max(1, qty * 24 * 60)

    # Safe fallback if unknown format
    return 1


def _extract_labels_from_path(file_path: Path) -> dict[str, str]:
    """Extract labels from file path. Returns empty dict; override for org-specific extraction."""
    return {}


def convert_values(doc: Any, report: ConversionReport, file_path: Path | None = None) -> tuple[Any, bool]:
    """Convert a single values document.  Returns (converted_values, was_wrapped)."""
    if not isinstance(doc, dict):
        report.add_warning("Top-level YAML document is not a mapping; skipping document.")
        return doc, False

    values = doc
    was_wrapped = False
    if "tra-nifi" in values and isinstance(values.get("tra-nifi"), dict):
        values = values["tra-nifi"]
        was_wrapped = True
        report.add_change("Unwrapped top-level tra-nifi block")

    # 0) Set default labels from file path and defaults
    if file_path:
        extracted_labels = _extract_labels_from_path(file_path)
        labels = _as_dict(values.get("labels"))
        for key, default_value in extracted_labels.items():
            if key not in labels or not labels.get(key):
                labels[key] = default_value
                report.add_change(f"Set labels.{key}={default_value}")
        values["labels"] = labels
    else:
        labels = _as_dict(values.get("labels"))
        values["labels"] = labels

    # 0b) Set caSecrets default — grouped with cluster/label config.
    # Prefer fullnameOverride as the prefix; fall back to properties.instanceName.
    _full_name_override = str(values.get("fullnameOverride", "")).strip()
    _instance_name = str(_as_dict(values.get("properties")).get("instanceName", "")).strip()
    _ca_prefix = _full_name_override or _instance_name
    existing_ca_secrets = _as_list(values.get("caSecrets"))
    if _ca_prefix and not existing_ca_secrets:
        derived = f"{_ca_prefix}-ca-secrets"
        values["caSecrets"] = [derived]
        _ca_source = "fullnameOverride" if _full_name_override else "properties.instanceName"
        report.add_change(
            f"Set caSecrets=[{derived}] (derived from {_ca_source})"
        )

    # 1) Logging -> clusterLogging
    if "Logging" in values:
        if "clusterLogging" not in values:
            values["clusterLogging"] = values["Logging"]
            report.add_change("Renamed Logging -> clusterLogging")
        else:
            report.add_warning("Both Logging and clusterLogging exist; kept clusterLogging and removed Logging")
        values.pop("Logging", None)

    # 2) Remove dead blocks removed in 2.10
    for removed_key in ("hashicorp", "ca", "openldap"):
        if removed_key in values:
            values.pop(removed_key, None)
            report.add_change(f"Removed deprecated top-level block: {removed_key}")

    # 2b) Shared node identity mapping migration
    # The chart now uses auth.nodeIdentity.shared.* and no longer reads
    # certManager.useSharedNodeIdentityMapping/sharedNodeIdentityCN.
    auth = _as_dict(values.get("auth"))
    values["auth"] = auth
    node_identity = _as_dict(auth.get("nodeIdentity"))
    shared_node = _as_dict(node_identity.get("shared"))

    # Support older auth.identityMapping.sharedNode input during uplift.
    legacy_identity_mapping = _as_dict(auth.get("identityMapping"))
    legacy_auth_shared_node = _as_dict(legacy_identity_mapping.get("sharedNode"))
    if legacy_auth_shared_node:
        if "enabled" not in shared_node and "enabled" in legacy_auth_shared_node:
            shared_node["enabled"] = _to_bool(legacy_auth_shared_node.get("enabled"), default=False)
            report.add_change(
                "Migrated auth.identityMapping.sharedNode.enabled -> auth.nodeIdentity.shared.enabled"
            )
        if (
            not str(shared_node.get("identity", "")).strip()
            and str(legacy_auth_shared_node.get("commonName", "")).strip()
        ):
            shared_node["identity"] = str(legacy_auth_shared_node.get("commonName", "")).strip()
            report.add_change(
                "Migrated auth.identityMapping.sharedNode.commonName -> auth.nodeIdentity.shared.identity"
            )
        auth.pop("identityMapping", None)

    cert_manager = _as_dict(values.get("certManager"))
    values["certManager"] = cert_manager

    legacy_enabled_present = "useSharedNodeIdentityMapping" in cert_manager
    legacy_enabled = cert_manager.pop("useSharedNodeIdentityMapping", None)
    if legacy_enabled_present and "enabled" not in shared_node:
        shared_node["enabled"] = _to_bool(legacy_enabled, default=False)
        report.add_change(
            "Migrated certManager.useSharedNodeIdentityMapping -> auth.nodeIdentity.shared.enabled"
        )

    legacy_cn_raw = cert_manager.pop("sharedNodeIdentityCN", None)
    legacy_cn = str(legacy_cn_raw).strip() if legacy_cn_raw is not None else ""
    if legacy_cn and not str(shared_node.get("identity", "")).strip():
        shared_node["identity"] = legacy_cn
        report.add_change(
            "Migrated certManager.sharedNodeIdentityCN -> auth.nodeIdentity.shared.identity"
        )

    # If a shared CN was defined in legacy values but enablement was omitted,
    # assume intent was to use shared identity mapping.
    if legacy_cn and "enabled" not in shared_node:
        shared_node["enabled"] = True
        report.add_change(
            "Set auth.nodeIdentity.shared.enabled=true (inferred from legacy sharedNodeIdentityCN)"
        )

    # Default enablement for 2.10+ values when not explicitly specified.
    if "enabled" not in shared_node:
        shared_node["enabled"] = True
        report.add_change(
            "Set auth.nodeIdentity.shared.enabled=true (default)"
        )

    if shared_node:
        node_identity["shared"] = shared_node
        auth["nodeIdentity"] = node_identity

    # 3) properties conversions
    properties = _as_dict(values.get("properties"))
    values["properties"] = properties
    force_file_mode = False

    # 3b) Migrate legacy GC flags from extraOptions -> jvm.gcCollector.
    # Old overrides often used java.arg.13=-XX:+UseG1GC.
    jvm = _as_dict(values.get("jvm"))
    values["jvm"] = jvm
    extra_options = _as_list(values.get("extraOptions"))
    if extra_options:
        kept_options: list[Any] = []
        for idx, opt in enumerate(extra_options):
            if not isinstance(opt, dict):
                kept_options.append(opt)
                continue

            name = str(opt.get("name", "")).strip()
            value = str(opt.get("value", "")).strip()

            is_gc_flag = name in {"java.arg.13", "java.arg.20"}
            if not is_gc_flag:
                kept_options.append(opt)
                continue

            target_gc = None
            if value == "-XX:+UseG1GC":
                target_gc = "g1gc"
            elif value == "-XX:+UseZGC":
                target_gc = "zgc"

            if target_gc is None:
                kept_options.append(opt)
                continue

            existing_gc = str(jvm.get("gcCollector", "")).strip().lower()
            if existing_gc and existing_gc != target_gc:
                report.add_warning(
                    "extraOptions[%d] requests %s but jvm.gcCollector is already %s; "
                    "kept the extra option to avoid changing behavior"
                    % (idx, target_gc, existing_gc)
                )
                kept_options.append(opt)
                continue

            if not existing_gc:
                jvm["gcCollector"] = target_gc
                report.add_change(
                    "Set jvm.gcCollector=%s (from extraOptions[%d] %s=%s)"
                    % (target_gc, idx, name, value)
                )

            report.add_change(
                "Removed redundant extraOptions[%d] %s=%s (managed by jvm.gcCollector)"
                % (idx, name, value)
            )

        values["extraOptions"] = kept_options

    # 3c) Migrate old NiFi image repository to new path.
    image_raw = values.get("image")
    image = _as_dict(image_raw)
    # Some legacy files represent image as a single string: repo:tag
    if not image and isinstance(image_raw, str):
        repo, tag = _split_image_ref(image_raw.strip())
        image = {"repository": repo, "tag": tag} if repo else {}

    # 3d) Consolidate image:, sidecar:, utilityImage: into unified images: section.
    images = _as_dict(values.get("images"))

    # -- nifi sub-key: merge legacy image fields into images.nifi without
    # clobbering explicit images.nifi values.
    nifi_img = _as_dict(images.get("nifi"))
    migrated_nifi = False
    if image:
        if not nifi_img.get("repository") and image.get("repository"):
            nifi_img["repository"] = image.get("repository")
            migrated_nifi = True
        if not nifi_img.get("tag") and image.get("tag"):
            nifi_img["tag"] = str(image.get("tag"))
            migrated_nifi = True
        if not nifi_img.get("pullPolicy"):
            pull_policy = image.get("pullPolicy") or image.get("imagePullPolicy")
            if pull_policy:
                nifi_img["pullPolicy"] = pull_policy
                migrated_nifi = True
        if not nifi_img.get("pullSecret") and image.get("pullSecret"):
            nifi_img["pullSecret"] = image.get("pullSecret")
            migrated_nifi = True

    if migrated_nifi:
        report.add_change("Migrated/merged image.* -> images.nifi")
    images["nifi"] = _normalize_image_map(nifi_img)
    values.pop("image", None)

    # -- utility sub-key: prefer images.utility, fall back to legacy utilityImage:
    utility_img = _as_dict(images.get("utility"))
    if not utility_img:
        legacy_utility = _as_dict(values.get("utilityImage"))
        legacy_full_image = legacy_utility.get("image", "")
        if isinstance(legacy_full_image, str) and ":" in legacy_full_image:
            repo, tag = legacy_full_image.rsplit(":", 1)
        else:
            repo, tag = legacy_full_image, ""
        if repo:
            utility_img = {
                "repository": repo,
                "tag": tag,
                "pullPolicy": legacy_utility.get("imagePullPolicy", "IfNotPresent"),
            }
            report.add_change("Migrated utilityImage.* -> images.utility")
    images["utility"] = _normalize_image_map(utility_img)
    values.pop("utilityImage", None)

    # -- sidecar sub-key: prefer images.sidecar, fall back to legacy sidecar:
    sidecar_img = _as_dict(images.get("sidecar"))
    if not sidecar_img:
        legacy_sidecar = _as_dict(values.get("sidecar"))
        legacy_repo = legacy_sidecar.get("image") or legacy_sidecar.get("repository", "")
        legacy_tag = str(legacy_sidecar.get("tag", ""))
        legacy_pull = legacy_sidecar.get("imagePullPolicy") or legacy_sidecar.get("pullPolicy", "IfNotPresent")
        if legacy_repo:
            sidecar_img = {
                "repository": legacy_repo,
                "tag": legacy_tag,
                "pullPolicy": legacy_pull,
            }
            report.add_change("Migrated sidecar.* -> images.sidecar")
    images["sidecar"] = _normalize_image_map(sidecar_img)
    values.pop("sidecar", None)

    values["images"] = images

    if properties.get("UseK8sSecrets") is True:

        if not properties.get("secretsMode"):
            properties["secretsMode"] = "directory"
            report.add_change("Set properties.secretsMode=directory (from UseK8sSecrets=true)")
        force_file_mode = True
    if "UseK8sSecrets" in properties:
        properties.pop("UseK8sSecrets", None)
        report.add_change("Removed properties.UseK8sSecrets (removed in 2.10)")

    if properties.get("secretsMode") == "env":
        properties["secretsMode"] = "directory"
        report.add_change("Mapped properties.secretsMode: env -> directory")
        force_file_mode = True

    if properties.get("secretsMode") == "file-dir":
        properties["secretsMode"] = "directory"
        report.add_change("Mapped properties.secretsMode: file-dir -> directory")
    elif properties.get("secretsMode") == "file-single":
        properties["secretsMode"] = "singlefile"
        report.add_change("Mapped properties.secretsMode: file-single -> singlefile")

    if "useFileSecrets" in properties:
        properties.pop("useFileSecrets", None)
        report.add_change("Removed properties.useFileSecrets (dead key in 2.10)")

    # Set pythonExtensionsSourceDir if not already configured.
    if not properties.get("pythonExtensionsSourceDir"):
        properties["pythonExtensionsSourceDir"] = "/opt/nifi/data/custom/python-extensions"
        report.add_change(
            "Set properties.pythonExtensionsSourceDir=/opt/nifi/data/custom/python-extensions (default)"
        )

    # 4) NiFiSync conversions
    nifi_sync = _as_dict(values.get("NiFiSync"))
    values["NiFiSync"] = nifi_sync

    # Ensure custom-python-extensions sync path is present.
    _sync_paths = _as_list(nifi_sync.get("syncPaths"))
    _py_ext = "custom-python-extensions"
    if not any(
        isinstance(p, dict) and p.get("pathName") == _py_ext
        for p in _sync_paths
    ):
        _sync_paths.append({
            "pathName": _py_ext,
            "localPath": "/opt/nifi/data/custom/python-extensions",
            "remotePath": "custom/python-extensions",
            "pathType": "fs",
        })
        nifi_sync["syncPaths"] = _sync_paths
        report.add_change("Added NiFiSync.syncPaths entry for custom-python-extensions")

    s3_sync = _as_dict(nifi_sync.get("s3Sync"))
    nifi_sync["s3Sync"] = s3_sync

    if "enable" in s3_sync and "enabled" not in s3_sync:
        s3_sync["enabled"] = s3_sync.pop("enable")
        report.add_change("Renamed NiFiSync.s3Sync.enable -> enabled")
    elif "enable" in s3_sync and "enabled" in s3_sync:
        s3_sync.pop("enable", None)
        report.add_warning("Found both NiFiSync.s3Sync.enable and enabled; kept enabled")

    sidecar = _as_dict(s3_sync.get("sidecar"))
    sidecar_image = sidecar.get("image")

    # If utility image is unset but s3Sync carries an explicit image override,
    # promote that override to images.utility and clear the per-feature override.
    utility_img_current = _as_dict(images.get("utility"))
    utility_repo_current = str(utility_img_current.get("repository", "")).strip()
    if isinstance(sidecar_image, str) and sidecar_image and not utility_repo_current:
        repo, tag = _split_image_ref(sidecar_image)
        if repo:
            images["utility"] = _normalize_image_map({
                "repository": repo,
                "tag": tag,
                "pullPolicy": utility_img_current.get("pullPolicy", "IfNotPresent"),
            })
            values["images"] = images
            sidecar["image"] = ""
            s3_sync["sidecar"] = sidecar
            report.add_change(
                "Promoted NiFiSync.s3Sync.sidecar.image -> images.utility and cleared s3Sync override"
            )
            sidecar_image = ""

    flow_restore = _as_dict(s3_sync.get("flowRestore"))
    if flow_restore:
        if "interval" in flow_restore and "intervalMinutes" not in flow_restore:
            old = flow_restore.pop("interval")
            flow_restore["intervalMinutes"] = _parse_old_flow_restore_interval_to_minutes(old)
            report.add_change(
                "Renamed NiFiSync.s3Sync.flowRestore.interval -> intervalMinutes "
                f"(derived from {old!r})"
            )
        elif "interval" in flow_restore and "intervalMinutes" in flow_restore:
            flow_restore.pop("interval", None)
            report.add_warning(
                "Found both flowRestore.interval and intervalMinutes; kept intervalMinutes"
            )
        s3_sync["flowRestore"] = flow_restore

    # 4b) extraContainers: enforce minimum image versions.
    _MINIO_SIDEKICK_MIN = (7, 1, 2)
    _MINIO_SIDEKICK_MIN_TAG = "v7.1.2"
    extra_containers = _as_list(values.get("extraContainers"))
    for container in extra_containers:
        if not isinstance(container, dict):
            continue
        img = str(container.get("image", ""))
        if not img.startswith("minio/sidekick:"):
            continue
        tag = img.split(":", 1)[1].lstrip("v")
        try:
            parts = tuple(int(x) for x in tag.split("."))
        except ValueError:
            continue
        if parts < _MINIO_SIDEKICK_MIN:
            old_img = img
            container["image"] = f"minio/sidekick:{_MINIO_SIDEKICK_MIN_TAG}"
            report.add_change(
                f"Updated extraContainers minio/sidekick image: {old_img} -> "
                f"minio/sidekick:{_MINIO_SIDEKICK_MIN_TAG} (minimum required version)"
            )
    if extra_containers:
        values["extraContainers"] = extra_containers

    # 5) VaultNiFiSecrets conversions
    vault = _as_dict(values.get("VaultNiFiSecrets"))
    values["VaultNiFiSecrets"] = vault

    if vault.get("secretProvider") == "traVaultSecrets":
        vault["secretProvider"] = "vaultSidecar"
        report.add_change("Mapped VaultNiFiSecrets.secretProvider: traVaultSecrets -> vaultSidecar")

    if "traVaultSecrets" in vault:
        old_block = _as_dict(vault.pop("traVaultSecrets"))
        new_block = _as_dict(vault.get("vaultSidecar"))
        merged = {**old_block, **new_block}
        vault["vaultSidecar"] = merged
        report.add_change("Renamed VaultNiFiSecrets.traVaultSecrets -> vaultSidecar")

    if "vaultSidecarImage" in vault:
        image = vault.pop("vaultSidecarImage")
        sidecar = _as_dict(vault.get("vaultSidecar"))
        if not sidecar.get("image") and image:
            sidecar["image"] = image
            report.add_change("Moved VaultNiFiSecrets.vaultSidecarImage -> vaultSidecar.image")
        else:
            report.add_warning(
                "vaultSidecarImage found but vaultSidecar.image already set; kept vaultSidecar.image"
            )
        vault["vaultSidecar"] = sidecar

    default_secret_mode = vault.get("defaultSecretMode")
    if default_secret_mode == "env":
        vault["defaultSecretMode"] = "directory"
        report.add_change("Mapped VaultNiFiSecrets.defaultSecretMode: env -> directory")
        force_file_mode = True

    secrets = _as_list(vault.get("secrets"))
    for idx, item in enumerate(secrets):
        if not isinstance(item, dict):
            continue
        if item.get("secretMode") == "env":
            item["secretMode"] = "directory"
            report.add_change(
                f"Mapped VaultNiFiSecrets.secrets[{idx}].secretMode: env -> directory"
            )
            # Preserve behavior for file-dir readers by flattening to secretsFilePath.
            if "flattenTo" not in item:
                item["flattenTo"] = properties.get("secretsFilePath", "/opt/nifi/secrets")
                report.add_change(
                    f"Set VaultNiFiSecrets.secrets[{idx}].flattenTo to properties.secretsFilePath"
                )
            force_file_mode = True
    vault["secrets"] = secrets

    if force_file_mode and not properties.get("secretsMode"):
        properties["secretsMode"] = "directory"
        report.add_change("Set properties.secretsMode=directory to keep file-based secret loading")

    # Set VaultNiFiSecrets defaults for configured (enabled) instances.
    if vault.get("enabled"):
        if not vault.get("defaultContainerPath"):
            vault["defaultContainerPath"] = "/opt/nifi/secrets"
            report.add_change(
                "Set VaultNiFiSecrets.defaultContainerPath=/opt/nifi/secrets (default)"
            )

    # Drop VaultNiFiSecrets entirely when it carries only empty defaults
    # (i.e. not enabled and nothing meaningful configured).
    _vault_meaningful_keys = {k for k in vault if k not in ("enabled", "secrets")}
    _vault_is_empty = (
        not vault.get("enabled")
        and not _as_list(vault.get("secrets"))
        and not _vault_meaningful_keys
    )
    if _vault_is_empty:
        values.pop("VaultNiFiSecrets", None)
        report.add_change("Omitted VaultNiFiSecrets (no configuration set)")

    return values, was_wrapped


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-i", "--input", required=True, help="Input values YAML file")
    parser.add_argument("-o", "--output", help="Output values YAML file")
    parser.add_argument(
        "--inplace",
        action="store_true",
        help="Overwrite the input file in-place",
    )
    return parser.parse_args()


def _timestamp_utc() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _make_backup_path(in_path: Path) -> Path:
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    base = in_path.with_name(f"{in_path.name}.bak.{ts}")
    if not base.exists():
        return base
    idx = 1
    while True:
        candidate = in_path.with_name(f"{in_path.name}.bak.{ts}.{idx}")
        if not candidate.exists():
            return candidate
        idx += 1


def _build_header(
    source_path: Path,
    out_path: Path,
    backup_path: Path | None,
    report: ConversionReport,
) -> str:
    lines = [
        "# -----------------------------------------------------------------------------",
        "# Uplifted to tra-nifi 2.10-compatible values",
        f"# Generated at (UTC): {_timestamp_utc()}",
        f"# Source file: {source_path}",
        f"# Output file: {out_path}",
        f"# Backup file: {backup_path if backup_path is not None else 'n/a'}",
        "# Converter: tools/convert_values_to_2_10.py",
        f"# Changes applied: {len(report.changes)}",
        f"# Warnings: {len(report.warnings)}",
        "# -----------------------------------------------------------------------------",
        "",
    ]
    return "\n".join(lines)


def main() -> int:
    args = parse_args()

    in_path = Path(args.input)
    if not in_path.exists():
        print(f"Input file not found: {in_path}", file=sys.stderr)
        return 2

    if args.inplace and args.output:
        print("Use either --inplace or --output, not both.", file=sys.stderr)
        return 2

    out_path = in_path if args.inplace else Path(args.output) if args.output else in_path.with_suffix(".2.10.yaml")
    backup_path: Path | None = None

    if args.inplace:
        backup_path = _make_backup_path(in_path)
        backup_path.write_text(in_path.read_text(encoding="utf-8"), encoding="utf-8")

    raw = in_path.read_text(encoding="utf-8")
    docs = list(yaml.safe_load_all(raw))

    report = ConversionReport()
    results = [convert_values(doc, report, in_path) for doc in docs]
    converted = [r[0] for r in results]
    was_wrapped = any(r[1] for r in results)

    # Re-wrap under tra-nifi: when writing back inplace to preserve umbrella chart format.
    # When writing to a separate output file (e.g. for helm template), keep unwrapped.
    if was_wrapped and args.inplace:
        converted = [{"tra-nifi": v} for v in converted]

    # Use single-document dump with section organization
    if len(converted) == 1 and not was_wrapped:
        converted_yaml = _reorganize_values_with_sections(converted[0])
    elif len(converted) == 1 and was_wrapped and args.inplace:
        # Emit tra-nifi: wrapper with inner content reorganized
        inner_yaml = _reorganize_values_with_sections(converted[0]["tra-nifi"])
        # Indent inner YAML under the tra-nifi: key
        indented = "\n".join(
            ("  " + line) if line.strip() else ""
            for line in inner_yaml.splitlines()
        )
        converted_yaml = "tra-nifi:\n" + indented + "\n"
    else:
        # Fallback for multi-doc: use standard dump without sections
        converted_yaml = yaml.safe_dump_all(
            converted,
            sort_keys=False,
            default_flow_style=False,
            allow_unicode=False,
            explicit_start=False,
        )

    header = _build_header(in_path, out_path, backup_path, report)
    out_path.write_text(header + converted_yaml, encoding="utf-8")

    print(f"Wrote converted values: {out_path}")
    if backup_path is not None:
        print(f"Backup created: {backup_path}")
    if report.changes:
        print("\nChanges:")
        for line in report.changes:
            print(f"- {line}")
    else:
        print("\nChanges:\n- (none)")

    if report.warnings:
        print("\nWarnings:")
        for line in report.warnings:
            print(f"- {line}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
