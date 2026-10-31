"""Persistent workstation region configuration."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

from .protocol import RegionConfig


class ConfigError(ValueError):
    """Raised when a workstation layout cannot be loaded or validated."""


DEFAULT_WIDTH = 1280
DEFAULT_HEIGHT = 720
DEFAULT_REGIONS = (
    RegionConfig(region_id=1, x0=0, y0=0, x1=1280, y1=240),
    RegionConfig(region_id=2, x0=0, y0=240, x1=1280, y1=480),
    RegionConfig(region_id=3, x0=0, y0=480, x1=1280, y1=720),
)


@dataclass(frozen=True)
class RegionLayout:
    """Display dimensions and the fixed regions used by the first demo."""

    width: int = DEFAULT_WIDTH
    height: int = DEFAULT_HEIGHT
    regions: tuple[RegionConfig, ...] = DEFAULT_REGIONS


def default_layout() -> RegionLayout:
    """Return a fresh default layout for the 1280x720 demo."""
    return RegionLayout(regions=tuple(DEFAULT_REGIONS))


def load_layout(path: str | Path) -> RegionLayout:
    """Load a layout from JSON, or return defaults when the file is absent."""
    layout_path = Path(path)
    if not layout_path.exists():
        return default_layout()

    try:
        with layout_path.open("r", encoding="utf-8") as config_file:
            document = json.load(config_file)
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError(f"cannot read layout: {layout_path}") from exc

    try:
        width = document["width"]
        height = document["height"]
        region_documents = document["regions"]
        regions = tuple(
            RegionConfig(
                region_id=region["region_id"],
                x0=region["x0"],
                y0=region["y0"],
                x1=region["x1"],
                y1=region["y1"],
            )
            for region in region_documents
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise ConfigError("layout has missing or invalid fields") from exc

    layout = RegionLayout(width=width, height=height, regions=regions)
    validate_layout(layout)
    return layout


def save_layout(path: str | Path, layout: RegionLayout) -> None:
    """Validate and write a layout as readable JSON."""
    validate_layout(layout)
    layout_path = Path(path)
    document = {
        "width": layout.width,
        "height": layout.height,
        "regions": [
            {
                "region_id": region.region_id,
                "x0": region.x0,
                "y0": region.y0,
                "x1": region.x1,
                "y1": region.y1,
            }
            for region in layout.regions
        ],
    }
    try:
        layout_path.parent.mkdir(parents=True, exist_ok=True)
        with layout_path.open("w", encoding="utf-8") as config_file:
            json.dump(document, config_file, indent=2)
            config_file.write("\n")
    except OSError as exc:
        raise ConfigError(f"cannot write layout: {layout_path}") from exc


def validate_layout(layout: RegionLayout) -> None:
    """Check dimensions, region bounds, IDs, and overlap-free regions."""
    if not isinstance(layout.width, int) or not 1 <= layout.width <= 4096:
        raise ConfigError("width must be between 1 and 4096")
    if not isinstance(layout.height, int) or not 1 <= layout.height <= 4096:
        raise ConfigError("height must be between 1 and 4096")
    if not layout.regions:
        raise ConfigError("at least one region is required")

    region_ids: set[int] = set()
    for region in layout.regions:
        if not isinstance(region.region_id, int) or not 0 <= region.region_id <= 15:
            raise ConfigError("region_id must be between 0 and 15")
        if region.region_id in region_ids:
            raise ConfigError("region IDs must be unique")
        region_ids.add(region.region_id)

        coordinates = (region.x0, region.y0, region.x1, region.y1)
        if any(not isinstance(value, int) for value in coordinates):
            raise ConfigError("region coordinates must be integers")
        if not (0 <= region.x0 < region.x1 <= layout.width):
            raise ConfigError("region x coordinates are out of bounds")
        if not (0 <= region.y0 < region.y1 <= layout.height):
            raise ConfigError("region y coordinates are out of bounds")

    for index, first in enumerate(layout.regions):
        for second in layout.regions[index + 1 :]:
            overlaps = (
                first.x0 < second.x1
                and second.x0 < first.x1
                and first.y0 < second.y1
                and second.y0 < first.y1
            )
            if overlaps:
                raise ConfigError("regions must not overlap")
