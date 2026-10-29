#!/usr/bin/env python3
"""Convert a speaker layout to one ASIO output without changing speaker positions."""
import argparse
import configparser
from pathlib import Path
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--layout", type=Path, default=Path(__file__).resolve().parent.parent / "configs/asio-714.ini")
    parser.add_argument("--driver", required=True, help="CLSID from list-asio")
    parser.add_argument("--channels", help="Comma-separated, one-based physical outputs; default 1..speaker count")
    parser.add_argument("--buffer-frames", type=int, default=0, help="0 selects the driver preferred period")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    driver = "{" + str(uuid.UUID(args.driver.strip("{}"))) + "}"
    if not 0 <= args.buffer_frames <= 2_147_483_647:
        parser.error("buffer-frames must fit a nonnegative Windows ASIO long")
    data = args.layout.read_bytes()
    encoding = "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
    config = configparser.ConfigParser(interpolation=None)
    config.read_string(data.decode(encoding))
    speakers = [item.strip() for item in config["layout"]["speakers"].split(",")]
    if len(speakers) < 2 or any(not name for name in speakers) or len({name.lower() for name in speakers}) != len(speakers):
        parser.error("layout must contain at least two unique speakers")
    if any("speaker." + name not in config for name in speakers):
        parser.error("layout is missing a speaker position")
    channels = (list(map(int, args.channels.split(","))) if args.channels
                else list(range(1, len(speakers) + 1)))
    if (len(channels) != len(speakers) or len(set(channels)) != len(channels)
            or min(channels) < 1 or max(channels) > 2_147_483_647):
        parser.error("channels must contain one unique positive ASIO output per speaker")
    if args.output.exists():
        parser.error("output already exists; choose a new file to preserve your profiles")
    name = config.get("profile", "name", fallback=config.get("layout", "name", fallback="ASIO layout"))
    for section in list(config.sections()):
        if section.lower().startswith("output."):
            config.remove_section(section)
    if not config.has_section("profile"):
        config.add_section("profile")
    config["profile"]["version"] = "2"
    config["profile"]["id"] = str(uuid.uuid4())
    config["profile"]["layout"] = config.get("profile", "layout", fallback="custom")
    config["profile"]["name"] = name + " (ASIO)"
    config["layout"]["outputs"] = "asio"
    config["layout"]["master"] = "asio"
    config["output.asio"] = {
        "backend": "asio", "asio_driver": driver,
        "endpoint_id": "asio:" + driver, "endpoint_name": "ASIO " + driver,
        "expected_channels": str(max(channels)),
        "asio_channels": ",".join(map(str, channels)),
        "asio_buffer_frames": str(args.buffer_frames),
        "speakers": ",".join(speakers), "delay_ms": "0",
    }
    # Win32 INI APIs recognize UTF-16LE with a BOM, including non-ASCII names.
    with args.output.open("x", encoding="utf-16") as stream:
        config.write(stream)
    print(f"Created {args.output}: {len(speakers)} speakers, physical outputs {min(channels)}..{max(channels)}")


if __name__ == "__main__":
    main()
