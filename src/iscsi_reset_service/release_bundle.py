"""Render a digest-pinned TrueNAS Custom App bundle for a GitHub release."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

IMAGE_PLACEHOLDER = (
    "ghcr.io/REPLACE_OWNER/iscsi-reset-service@sha256:REPLACE_WITH_IMMUTABLE_DIGEST"
)
EXPECTED_IMAGE_REFERENCES = 2
TEMPLATE_HEADER = "# Replace the image digest, management IP and every /mnt/tank/... path."
RELEASE_HEADER = "# Image is digest-pinned. Replace the management IP and every /mnt/tank/... path."

_DIGEST_PATTERN = re.compile(r"sha256:[0-9a-f]{64}\Z")
_IMAGE_REPOSITORY_PATTERN = re.compile(
    r"ghcr\.io/[a-z0-9]+(?:[._-][a-z0-9]+)*"
    r"(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)+\Z"
)


def render_truenas_bundle(
    template: str,
    *,
    image_repository: str,
    digest: str,
) -> str:
    """Replace exactly the two image placeholders with one immutable reference."""
    if not _IMAGE_REPOSITORY_PATTERN.fullmatch(image_repository):
        raise ValueError(
            "image repository must be a lowercase, untagged ghcr.io repository path"
        )
    if not _DIGEST_PATTERN.fullmatch(digest):
        raise ValueError("digest must match sha256 followed by 64 lowercase hexadecimal digits")

    placeholder_count = template.count(IMAGE_PLACEHOLDER)
    if placeholder_count != EXPECTED_IMAGE_REFERENCES:
        raise ValueError(
            f"expected {EXPECTED_IMAGE_REFERENCES} image placeholders, found {placeholder_count}"
        )
    if template.count(TEMPLATE_HEADER) != 1:
        raise ValueError("expected exactly one template instruction header")

    pinned_image = f"{image_repository}@{digest}"
    rendered = template.replace(IMAGE_PLACEHOLDER, pinned_image).replace(
        TEMPLATE_HEADER,
        RELEASE_HEADER,
    )

    if "REPLACE_OWNER" in rendered or "REPLACE_WITH_IMMUTABLE_DIGEST" in rendered:
        raise ValueError("rendered bundle still contains an image placeholder")
    if rendered.count(pinned_image) != EXPECTED_IMAGE_REFERENCES:
        raise ValueError("rendered bundle does not contain exactly two pinned image references")

    return rendered


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--image-repository", required=True)
    parser.add_argument("--digest", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = _parser()
    args = parser.parse_args(argv)

    try:
        template = args.template.read_text(encoding="utf-8")
        rendered = render_truenas_bundle(
            template,
            image_repository=args.image_repository,
            digest=args.digest,
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    except (OSError, ValueError) as exc:
        parser.error(str(exc))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
