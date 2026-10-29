"""Generate custom-symbol SVG sources from Simple Icons using Apple's template.

Python 3.9+, standard library only. Output still needs SF Symbols/Xcode validation;
this does not compile assets or synthesize weight-specific logo artwork.
"""

import argparse
from copy import deepcopy
import math
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

SVG = "http://www.w3.org/2000/svg"
NS = {"svg": SVG}
ET.register_namespace("", SVG)
ET.register_namespace("xlink", "http://www.w3.org/1999/xlink")


def numbers(value):
    result = [float(part) for part in re.split(r"[\s,]+", value.strip())]
    if not all(math.isfinite(number) for number in result):
        raise ValueError("Non-finite SVG coordinate")
    return result


def read_template(path):
    root = ET.parse(path).getroot()
    if root.tag != f"{{{SVG}}}svg":
        raise ValueError("Template must use the SVG namespace")
    symbols = root.find("svg:g[@id='Symbols']", NS)
    guides = root.find("svg:g[@id='Guides']", NS)
    if symbols is None or guides is None:
        raise ValueError("Template needs Symbols and Guides groups")
    masters = list(symbols)
    if not masters:
        raise ValueError("Template has no symbol masters")
    # Check every master before writing any output. This supports the translated
    # masters in pencil.svg, not arbitrary templates with additional transforms.
    for master in masters:
        name = master.get("id", "")
        if master.tag != f"{{{SVG}}}g" or "-" not in name:
            raise ValueError("Unexpected element in Symbols")
        transform = re.fullmatch(r"matrix\(([^)]+)\)", master.get("transform", ""))
        if not transform:
            raise ValueError(f"{name}: expected a matrix transform")
        matrix = numbers(transform.group(1))
        if len(matrix) != 6 or matrix[:4] != [1, 0, 0, 1]:
            raise ValueError(f"{name}: only translation matrices are supported")
        scale = name.rsplit("-", 1)[1]
        for guide_id in (f"Baseline-{scale}", f"Capline-{scale}",
                         f"left-margin-{name}", f"right-margin-{name}"):
            if guides.find(f".//*[@id='{guide_id}']") is None:
                raise ValueError(f"Missing template guide: {guide_id}")
    return root


def convert(source, template, padding):
    icon = ET.parse(source).getroot()
    if icon.tag != f"{{{SVG}}}svg":
        raise ValueError("Source must use the SVG namespace")
    box = numbers(icon.get("viewBox", ""))
    if len(box) != 4 or box[2] <= 0 or box[3] <= 0:
        raise ValueError("Source needs a positive four-number viewBox")
    # Simple Icons are outlined, filled paths. Reject unsupported SVG features
    # rather than silently dropping transforms, styles, clipping, or shapes.
    if set(icon.attrib) - {"viewBox", "role", "width", "height", "version"}:
        raise ValueError("Unsupported root attributes; use original Simple Icons SVGs")
    paths = []
    for element in icon:
        if element.tag in (f"{{{SVG}}}title", f"{{{SVG}}}desc"):
            continue
        if element.tag != f"{{{SVG}}}path" or list(element):
            raise ValueError("Only outlined path artwork is supported")
        if set(element.attrib) - {"d", "fill", "fill-rule", "clip-rule"}:
            raise ValueError("Unsupported path attributes")
        if not element.get("d", "").strip() or element.get("fill") == "none":
            raise ValueError("Expected a nonempty filled path")
        path = deepcopy(element)
        path.set("fill", "black")
        paths.append(path)
    if not paths:
        raise ValueError("No path artwork found")

    root = deepcopy(template)
    symbols = root.find("svg:g[@id='Symbols']", NS)
    guides = root.find("svg:g[@id='Guides']", NS)
    for master in symbols:
        name = master.get("id")
        scale_name = name.rsplit("-", 1)[1]
        baseline = float(guides.find(f".//*[@id='Baseline-{scale_name}']").get("y1"))
        capline = float(guides.find(f".//*[@id='Capline-{scale_name}']").get("y1"))
        height = baseline - capline
        if not math.isfinite(height) or height <= 0:
            raise ValueError(f"{name}: invalid cap height")
        left = guides.find(f".//*[@id='left-margin-{name}']")
        right = guides.find(f".//*[@id='right-margin-{name}']")
        center = (float(left.get("x1")) + float(right.get("x1"))) / 2
        factor = height / max(box[2], box[3])
        width = box[2] * factor
        artwork_height = box[3] * factor
        origin = center - width / 2
        # Retain the template's master ID, but replace its artwork and positioning.
        master.attrib.clear()
        master.set("id", name)
        master.set("transform", f"matrix(1 0 0 1 {origin:.8g} {baseline:.8g})")
        for child in list(master):
            master.remove(child)
        x = -box[0] * factor
        y = -(height + artwork_height) / 2 - box[1] * factor
        artwork = ET.SubElement(master, f"{{{SVG}}}g", {
            "transform": f"matrix({factor:.8g} 0 0 {factor:.8g} {x:.8g} {y:.8g})"
        })
        for path in paths:
            artwork.append(deepcopy(path))
        for guide, coordinate in ((left, origin - height * padding),
                                  (right, origin + width + height * padding)):
            guide.set("x1", f"{coordinate:.8g}")
            guide.set("x2", f"{coordinate:.8g}")
    description = root.find(".//*[@id='descriptive-name']")
    if description is not None:
        description.text = f"Generated from {source.stem} (Simple Icons)"
    return ET.ElementTree(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Original SVG file or directory")
    parser.add_argument("output", type=Path, help="Destination directory")
    parser.add_argument("--template", type=Path,
                        default=Path(__file__).with_name("pencil.svg"))
    parser.add_argument("--overwrite", action="store_true",
                        help="Replace existing output SVGs (default: refuse)")
    parser.add_argument("--padding", type=float, default=0.08,
                        help="Side bearing as a fraction of cap height (default: 0.08)")
    args = parser.parse_args()
    if not math.isfinite(args.padding) or args.padding < 0:
        parser.error("--padding must be finite and nonnegative")
    source, output = args.source.resolve(), args.output.resolve()
    if not source.exists():
        parser.error("Source does not exist")
    if source.is_dir() and (output == source or source in output.parents):
        parser.error("Output must be outside the source directory")
    try:
        template = read_template(args.template)
        files = sorted(source.rglob("*.svg")) if source.is_dir() else [source]
        if not files:
            parser.error("No SVG files found")
        jobs = []
        names = set()
        for file in files:
            name = file.stem.lower().replace("-", "_") + ".svg"
            destination = output / name
            if name in names:
                raise ValueError(f"Output name collision: {name}")
            if destination.resolve() in (file.resolve(), args.template.resolve()):
                raise ValueError("Output would replace an input or template")
            if destination.exists() and not args.overwrite:
                raise ValueError(f"Already exists: {destination}; use --overwrite explicitly")
            names.add(name)
            jobs.append((file, destination))
        output.mkdir(parents=True, exist_ok=True)
    except (OSError, ValueError, ET.ParseError) as error:
        parser.error(str(error))

    failures = 0
    for file, destination in jobs:
        try:
            tree = convert(file, template, args.padding)
            # Complete serialization before opening an existing destination.
            data = ET.tostring(tree.getroot(), encoding="utf-8", xml_declaration=True)
            with destination.open("wb" if args.overwrite else "xb") as stream:
                stream.write(data)
        except (OSError, ValueError, ET.ParseError) as error:
            failures += 1
            print(f"FAILED {file}: {error}", file=sys.stderr)
    print(f"Generated {len(jobs) - failures}/{len(jobs)} symbol SVG sources; "
          f"{failures} failed. Validate in SF Symbols/Xcode before use.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
