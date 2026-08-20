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


def test_render_bundle_pins_all_services_and_preserves_site_placeholders() -> None:
    template = TEMPLATE_PATH.read_text(encoding="utf-8")

    rendered = render_truenas_bundle(
        template,
        image_repository=IMAGE_REPOSITORY,
        digest=VALID_DIGEST,
    )

    pinned_image = f"{IMAGE_REPOSITORY}@{VALID_DIGEST}"
    assert rendered.count(f"image: {pinned_image}") == 3
    assert IMAGE_PLACEHOLDER not in rendered
    assert "REPLACE_OWNER" not in rendered
    assert "REPLACE_WITH_IMMUTABLE_DIGEST" not in rendered
    assert TEMPLATE_HEADER not in rendered
    assert RELEASE_HEADER in rendered
    assert "REPLACE_WITH_TRUENAS_MANAGEMENT_IP" in rendered
    assert rendered.count(
        "TRUENAS_API_URL: wss://REPLACE_WITH_TRUENAS_MANAGEMENT_IP/api/current"
    ) == 3
    assert "TRUENAS_API_URL: wss://127.0.0.1/api/current" not in rendered
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

    with pytest.raises(ValueError, match="expected 3 image placeholders, found 2"):
        render_truenas_bundle(
            template,
            image_repository=IMAGE_REPOSITORY,
            digest=VALID_DIGEST,
        )
