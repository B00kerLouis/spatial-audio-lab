#!/usr/bin/env python3
"""Run real ASIO host logic against test doubles on Linux; no Windows ABI test."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sanitize", choices=["address", "thread"])
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    flags = ["-std=c++20", "-Wall", "-Wextra", "-Werror", "-pthread", "-g"]
    if args.sanitize:
        flags += ["-fno-omit-frame-pointer", "-fsanitize=" +
                  ("address,undefined" if args.sanitize == "address" else "thread")]
    compiler = os.environ.get("CXX", "g++")
    with tempfile.TemporaryDirectory(prefix="sal-asio-tests-") as directory:
        build = Path(directory)
        source = build / "src"
        source.mkdir()
        # Isolate production files from Windows-only headers in a full checkout.
        for name in ["asio_renderer.cpp", "asio_renderer.h", "asio_audio.h", "pcm_queue.cpp",
                     "multi_endpoint_renderer.h", "speaker_layout.cpp", "speaker_layout.h"]:
            shutil.copy2(root / "src" / name, source / name)
        mock = root / "tests" / "asio_mock"
        for test, sources in [
            ("audio", [root / "tests/native/asio_audio_tests.cpp"]),
            ("host", [root / "tests/native/asio_host_tests.cpp", source / "asio_renderer.cpp",
                      source / "pcm_queue.cpp", source / "speaker_layout.cpp"]),
        ]:
            output = build / test
            command = [compiler, *flags, "-DSAL_ENABLE_ASIO=1", "-I" + str(source),
                       "-I" + str(mock), *map(str, sources), "-o", str(output)]
            subprocess.run(command, check=True)
            subprocess.run([str(output)], check=True, timeout=120)
        # Check the no-SDK production branch still compiles.
        subprocess.run([compiler, *flags, "-I" + str(source), "-I" + str(mock), "-c",
                        str(source / "asio_renderer.cpp"), "-o", str(build / "no-sdk.o")], check=True)


if __name__ == "__main__":
    main()
