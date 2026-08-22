import hashlib
import shutil
from pathlib import Path

import pytest

from iscsi_reset_service.release_bundle import (
    IMAGE_PLACEHOLDER,
    RELEASE_HEADER,
    TEMPLATE_HEADER,
    render_truenas_bundle,
)

ROOT = Path(__file__).resolve().parents[1]
TEMPLATE_PATH = ROOT / "truenas" / "custom-app.yaml"
VALID_DIGEST = f"sha256:{'a' * 64}"
IMAGE_REPOSITORY = "ghcr.io/xerz/iscsi-reset-service"
PUBLISH_WORKFLOW_PATH = ROOT / ".github" / "workflows" / "publish.yml"
OPERATOR_SCRIPTS = (
    "Install-IscsiReleasePublisher.ps1",
    "Install-IscsiResetClient.ps1",
    "Publish-IscsiRelease.ps1",
    "Reset-And-Connect.ps1",
)


def test_render_bundle_pins_all_services_and_preserves_site_placeholders() -> None:
    template = TEMPLATE_PATH.read_text(encoding="utf-8")

    rendered = render_truenas_bundle(
        template,
        image_repository=IMAGE_REPOSITORY,
        digest=VALID_DIGEST,
    )

    pinned_image = f"{IMAGE_REPOSITORY}@{VALID_DIGEST}"
    assert rendered.count(f"image: {pinned_image}") == 2
    assert IMAGE_PLACEHOLDER not in rendered
    assert "REPLACE_OWNER" not in rendered
    assert "REPLACE_WITH_IMMUTABLE_DIGEST" not in rendered
    assert TEMPLATE_HEADER not in rendered
    assert RELEASE_HEADER in rendered
    assert "REPLACE_WITH_TRUENAS_MANAGEMENT_IP" in rendered
    assert rendered.count(
        "TRUENAS_API_URL: wss://REPLACE_WITH_TRUENAS_MANAGEMENT_IP/api/current"
    ) == 2
    assert "TRUENAS_API_URL: wss://127.0.0.1/api/current" not in rendered
    assert "MANAGEMENT_BIND_HOST: 127.0.0.1" in rendered
    assert 'MANAGEMENT_BIND_PORT: "8445"' in rendered
    assert "8444" not in rendered
    assert "admin-server" not in rendered
    assert "admin-client" not in rendered
    assert "admin_token" not in rendered
    assert rendered.count("/mnt/tank/") == template.count("/mnt/tank/")


@pytest.mark.parametrize(
    "digest",
    [
        "sha256:short",
        f"sha256:{'A' * 64}",
        f"sha512:{'a' * 64}",
    ],
)
def test_render_bundle_rejects_invalid_digest(digest: str) -> None:
    template = TEMPLATE_PATH.read_text(encoding="utf-8")

    with pytest.raises(ValueError, match="digest must match"):
        render_truenas_bundle(
            template,
            image_repository=IMAGE_REPOSITORY,
            digest=digest,
        )


def test_render_bundle_rejects_uppercase_or_tagged_repository() -> None:
    template = TEMPLATE_PATH.read_text(encoding="utf-8")

    for repository in ("ghcr.io/Xerz/iscsi-reset-service", f"{IMAGE_REPOSITORY}:v0.2.0"):
        with pytest.raises(ValueError, match="lowercase, untagged"):
            render_truenas_bundle(
                template,
                image_repository=repository,
                digest=VALID_DIGEST,
            )


def test_render_bundle_rejects_unexpected_placeholder_count() -> None:
    template = TEMPLATE_PATH.read_text(encoding="utf-8").replace(IMAGE_PLACEHOLDER, "", 1)

    with pytest.raises(ValueError, match="expected 2 image placeholders, found 1"):
        render_truenas_bundle(
            template,
            image_repository=IMAGE_REPOSITORY,
            digest=VALID_DIGEST,
        )


def test_publish_workflow_packages_exact_operator_scripts() -> None:
    scripts = tuple(sorted(path.name for path in (ROOT / "powershell").glob("*.ps1")))
    workflow = PUBLISH_WORKFLOW_PATH.read_text(encoding="utf-8")

    assert scripts == OPERATOR_SCRIPTS
    assert "install -m 0644 powershell/*.ps1 dist/" in workflow
    assert 'sha256sum "${BUNDLE_NAME}" image-digest.txt *.ps1 > SHA256SUMS' in workflow
    assert workflow.count("dist/*.ps1") == 3
    for script in OPERATOR_SCRIPTS:
        assert script in workflow
    assert "dist/publisher.json" not in workflow
    assert "publisher.json" in workflow


def test_simulated_release_directory_has_seven_checksum_assets(tmp_path: Path) -> None:
    bundle_name = "iscsi-reset-service-v0.4.3-truenas.yaml"
    rendered = render_truenas_bundle(
        TEMPLATE_PATH.read_text(encoding="utf-8"),
        image_repository=IMAGE_REPOSITORY,
        digest=VALID_DIGEST,
    )
    (tmp_path / bundle_name).write_text(rendered, encoding="utf-8")
    (tmp_path / "image-digest.txt").write_text(
        f"{IMAGE_REPOSITORY}@{VALID_DIGEST}\n",
        encoding="utf-8",
    )
    for script in OPERATOR_SCRIPTS:
        shutil.copyfile(ROOT / "powershell" / script, tmp_path / script)

    checksummed = {bundle_name, "image-digest.txt", *OPERATOR_SCRIPTS}
    checksum_lines = []
    for name in sorted(checksummed):
        digest = hashlib.sha256((tmp_path / name).read_bytes()).hexdigest()
        checksum_lines.append(f"{digest}  {name}")
    (tmp_path / "SHA256SUMS").write_text(
        "\n".join(checksum_lines) + "\n",
        encoding="utf-8",
    )
    assets = checksummed | {"SHA256SUMS"}

    assert {path.name for path in tmp_path.iterdir()} == assets
    assert {
        line.split("  ", 1)[1]
        for line in (tmp_path / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
    } == checksummed
    assert len(assets) == 7
