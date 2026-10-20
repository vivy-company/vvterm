#!/usr/bin/env python3
"""Verify that VVTerm's shipped dependencies match its attribution manifest."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = REPOSITORY_ROOT / "VVTerm/Resources/OpenSource/Attributions.json"
PACKAGE_RESOLVED_PATH = (
    REPOSITORY_ROOT
    / "VVTerm.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)
BUILD_SCRIPT_PATH = REPOSITORY_ROOT / "scripts/build.sh"
MODEL_CATALOG_PATH = (
    REPOSITORY_ROOT
    / "VVTerm/Features/VoiceInput/Infrastructure/Models/MLXModelCatalog.swift"
)
MODEL_MANIFEST_PATH = (
    REPOSITORY_ROOT
    / "VVTerm/Features/VoiceInput/Infrastructure/Models/MLXModelDownloadManifest.swift"
)
LICENSE_DIRECTORY = REPOSITORY_ROOT / "VVTerm/Resources/OpenSource/Licenses"
NATIVE_ARTIFACT_MANIFEST_PATH = REPOSITORY_ROOT / "Vendor/native-artifacts.sha256"


def load_json(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as file:
        return json.load(file)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def compare(label: str, expected: Any, actual: Any, errors: list[str]) -> None:
    if expected != actual:
        errors.append(
            f"{label} differs.\n"
            f"  expected: {json.dumps(expected, sort_keys=True)}\n"
            f"  actual:   {json.dumps(actual, sort_keys=True)}"
        )


def verify_attributions(manifest: dict[str, Any], errors: list[str]) -> set[str]:
    entries = manifest.get("attributions", [])
    attribution_ids: set[str] = set()
    allowed_roles = {
        "terminalEngine",
        "networkTransport",
        "securityLibrary",
        "archiveLibrary",
        "machineLearningLibrary",
        "utilityLibrary",
        "sessionProtocol",
        "speechModel",
        "fontCollection",
        "themeCollection",
        "artwork",
    }

    if not entries:
        errors.append("The attribution list is empty.")
        return attribution_ids

    required_fields = {
        "id",
        "name",
        "role",
        "projectURL",
        "licenseName",
        "licenseResource",
    }
    for entry in entries:
        entry_id = entry.get("id", "<missing>")
        if set(entry) != required_fields:
            errors.append(f"Attribution {entry_id} has an invalid field set.")
        if entry_id in attribution_ids:
            errors.append(f"Duplicate attribution ID: {entry_id}")
        attribution_ids.add(entry_id)

        if entry.get("role") not in allowed_roles:
            errors.append(f"Attribution {entry_id} has an unknown role.")
        if not str(entry.get("projectURL", "")).startswith("https://"):
            errors.append(f"Attribution {entry_id} must use an HTTPS project URL.")

        resource = entry.get("licenseResource", "")
        if not resource or Path(resource).name != resource or not resource.endswith(".txt"):
            errors.append(f"Attribution {entry_id} has an invalid license resource.")
            continue
        resource_path = LICENSE_DIRECTORY / resource
        if not resource_path.is_file() or resource_path.stat().st_size == 0:
            errors.append(f"Attribution {entry_id} is missing {resource}.")

    return attribution_ids


def verify_reference(
    owner: str,
    attribution_id: Any,
    attribution_ids: set[str],
    errors: list[str],
) -> None:
    if attribution_id not in attribution_ids:
        errors.append(f"{owner} refers to unknown attribution ID {attribution_id!r}.")


def verify_swift_packages(
    inventory: dict[str, Any],
    attribution_ids: set[str],
    errors: list[str],
) -> None:
    resolved = load_json(PACKAGE_RESOLVED_PATH)
    actual = sorted(
        (
            {
                "identity": pin["identity"],
                "location": pin["location"],
                "state": pin["state"],
            }
            for pin in resolved["pins"]
        ),
        key=lambda pin: pin["identity"],
    )
    expected_records = inventory.get("swiftPackages", [])
    expected = sorted(
        (
            {
                "identity": pin["identity"],
                "location": pin["location"],
                "state": pin["state"],
            }
            for pin in expected_records
        ),
        key=lambda pin: pin["identity"],
    )
    compare("Swift package inventory", expected, actual, errors)

    for pin in expected_records:
        classification = pin.get("classification")
        owner = f"Swift package {pin.get('identity')}"
        if classification == "openSource":
            verify_reference(owner, pin.get("attributionID"), attribution_ids, errors)
        elif classification == "firstParty":
            if pin.get("attributionID") is not None:
                errors.append(f"{owner} is first party but has an attribution ID.")
        else:
            errors.append(f"{owner} has an unknown classification.")


def shell_value(source: str, name: str) -> str | None:
    match = re.search(rf'^{re.escape(name)}="([^"]+)"$', source, re.MULTILINE)
    return match.group(1) if match else None


def verify_native_dependencies(
    inventory: dict[str, Any],
    attribution_ids: set[str],
    errors: list[str],
) -> None:
    source = BUILD_SCRIPT_PATH.read_text(encoding="utf-8")
    ghostty_commit_match = re.search(
        r'^GHOSTTY_COMMIT="\$\{GHOSTTY_COMMIT:-([0-9a-f]{40})\}"$',
        source,
        re.MULTILINE,
    )
    actual = [
        {
            "id": "ghostty",
            "sourceURL": shell_value(source, "GHOSTTY_REPO"),
            "version": ghostty_commit_match.group(1) if ghostty_commit_match else None,
            "sourceSHA256": None,
        },
        {
            "id": "libssh2",
            "sourceURL": "https://github.com/libssh2/libssh2",
            "version": shell_value(source, "LIBSSH2_COMMIT"),
            "sourceSHA256": shell_value(source, "LIBSSH2_SHA256"),
        },
        {
            "id": "openssl",
            "sourceURL": "https://www.openssl.org/source/",
            "version": shell_value(source, "OPENSSL_VERSION"),
            "sourceSHA256": shell_value(source, "OPENSSL_SHA256"),
        },
    ]
    expected_records = inventory.get("nativeDependencies", [])
    expected = [
        {
            "id": dependency["id"],
            "sourceURL": dependency["sourceURL"],
            "version": dependency["version"],
            "sourceSHA256": dependency.get("sourceSHA256"),
        }
        for dependency in expected_records
    ]
    compare(
        "Native dependency inventory",
        sorted(expected, key=lambda dependency: dependency["id"]),
        sorted(actual, key=lambda dependency: dependency["id"]),
        errors,
    )

    for dependency in expected_records:
        verify_reference(
            f"Native dependency {dependency.get('id')}",
            dependency.get("attributionID"),
            attribution_ids,
            errors,
        )

    ghostty_version_path = REPOSITORY_ROOT / "Vendor/libghostty/VERSION"
    if not ghostty_version_path.is_file():
        errors.append("Vendor/libghostty/VERSION is missing.")
    elif ghostty_version_path.read_text(encoding="utf-8").strip() != actual[0]["version"]:
        errors.append("The vendored Ghostty version does not match scripts/build.sh.")

    verify_native_artifacts(errors)


def verify_native_artifacts(errors: list[str]) -> None:
    declared: set[str] = set()
    if not NATIVE_ARTIFACT_MANIFEST_PATH.is_file():
        errors.append("Vendor/native-artifacts.sha256 is missing.")
        return

    for line in NATIVE_ARTIFACT_MANIFEST_PATH.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (Vendor/.+\.a)", line)
        if not match:
            errors.append(f"Invalid native artifact manifest line: {line}")
            continue
        expected_hash, relative_path = match.groups()
        declared.add(relative_path)
        artifact_path = REPOSITORY_ROOT / relative_path
        if not artifact_path.is_file():
            errors.append(f"Native artifact is missing: {relative_path}")
        elif sha256(artifact_path) != expected_hash:
            errors.append(f"Native artifact hash differs: {relative_path}")

    actual = {
        path.relative_to(REPOSITORY_ROOT).as_posix()
        for path in (REPOSITORY_ROOT / "Vendor").rglob("*.a")
    }
    compare("Native artifact file set", sorted(declared), sorted(actual), errors)


def verify_model_assets(
    inventory: dict[str, Any],
    attribution_ids: set[str],
    errors: list[str],
) -> None:
    source = MODEL_MANIFEST_PATH.read_text(encoding="utf-8")
    pattern = re.compile(
        r'case \(\.(?:whisper|parakeetTDT), "([^"]+)"\):.*?'
        r'revision: "([0-9a-f]{40})"',
        re.DOTALL,
    )
    actual = [
        {"id": model_id, "revision": revision}
        for model_id, revision in pattern.findall(source)
    ]
    tokenizer_match = re.search(
        r'let tokenizerRevision = "([0-9a-f]{40})"', source
    )
    actual.append(
        {
            "id": "openai/whisper-tokenizer-assets",
            "revision": tokenizer_match.group(1) if tokenizer_match else None,
        }
    )

    expected_records = inventory.get("modelAssets", [])
    expected = [
        {"id": model["id"], "revision": model["revision"]}
        for model in expected_records
    ]
    compare(
        "Downloadable model inventory",
        sorted(expected, key=lambda model: model["id"]),
        sorted(actual, key=lambda model: model["id"]),
        errors,
    )

    catalog_source = MODEL_CATALOG_PATH.read_text(encoding="utf-8")
    catalog_ids = sorted(set(re.findall(r'id: "(mlx-community/[^"]+)"', catalog_source)))
    downloadable_ids = sorted(
        model["id"] for model in expected_records if model["id"].startswith("mlx-community/")
    )
    compare("Model catalog IDs", downloadable_ids, catalog_ids, errors)

    for model in expected_records:
        verify_reference(
            f"Model asset {model.get('id')}",
            model.get("attributionID"),
            attribution_ids,
            errors,
        )


def matching_files(patterns: list[str]) -> list[Path]:
    matches: set[Path] = set()
    for pattern in patterns:
        for path in REPOSITORY_ROOT.glob(pattern):
            if path.is_file():
                matches.add(path)
    return sorted(matches, key=lambda path: path.relative_to(REPOSITORY_ROOT).as_posix())


def resource_group_digest(files: list[Path]) -> str:
    digest = hashlib.sha256()
    for path in files:
        relative_path = path.relative_to(REPOSITORY_ROOT).as_posix().encode("utf-8")
        digest.update(relative_path)
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def verify_resource_groups(
    inventory: dict[str, Any],
    attribution_ids: set[str],
    errors: list[str],
) -> None:
    seen_ids: set[str] = set()
    for group in inventory.get("resourceGroups", []):
        group_id = group.get("id", "<missing>")
        if group_id in seen_ids:
            errors.append(f"Duplicate resource group ID: {group_id}")
        seen_ids.add(group_id)

        files = matching_files(group.get("patterns", []))
        compare(
            f"Resource group {group_id} file count",
            group.get("fileCount"),
            len(files),
            errors,
        )
        compare(
            f"Resource group {group_id} digest",
            group.get("sha256"),
            resource_group_digest(files),
            errors,
        )
        for attribution_id in group.get("attributionIDs", []):
            verify_reference(
                f"Resource group {group_id}",
                attribution_id,
                attribution_ids,
                errors,
            )


def main() -> int:
    errors: list[str] = []
    try:
        manifest = load_json(MANIFEST_PATH)
    except (OSError, json.JSONDecodeError) as error:
        print(f"Unable to read {MANIFEST_PATH}: {error}", file=sys.stderr)
        return 1

    if manifest.get("schemaVersion") != 1:
        errors.append("Attributions.json must use schema version 1.")

    attribution_ids = verify_attributions(manifest, errors)
    inventory = manifest.get("inventory", {})
    verify_swift_packages(inventory, attribution_ids, errors)
    verify_native_dependencies(inventory, attribution_ids, errors)
    verify_model_assets(inventory, attribution_ids, errors)
    verify_resource_groups(inventory, attribution_ids, errors)

    if errors:
        print("Attribution verification failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(
        "Attribution inventory is current "
        f"({len(inventory['swiftPackages'])} Swift packages, "
        f"{len(inventory['nativeDependencies'])} native dependencies, "
        f"{len(inventory['modelAssets'])} model assets, "
        f"{len(inventory['resourceGroups'])} resource groups, "
        f"{len(attribution_ids)} attributions)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
