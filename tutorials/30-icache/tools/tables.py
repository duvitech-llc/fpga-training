#!/usr/bin/env python3
"""Prints the RESULT lines of make measure as one Markdown table per program.

    python3 tools/tables.py build/measure_*.log

Each row is one cache, each column a place the program ran from: RAM with no
wait, RAM with three wait states, and the flash. A cell is clocks per
instruction. The hit rate is the same wherever the program ran from, since the
fetches are the same, so it has one column; the script checks that it is the
same.
"""

import re
import sys

LINE = re.compile(r"RESULT (\d+) x (\d+) (\w+)\s+(\w+)\s+(\w+)\s+(\d+) clocks\s+(\d+) instrs\s+"
                  r"CPI\s+([\d.]+)\s+hits\s+(\d+) misses\s+(\d+)\s+hit rate\s+([\d.]+)%")


def label(lines, words, stream):
    flash = "streamed" if stream == "stream" else "one word per command"
    if lines == 0:
        return f"no cache, flash {flash}"
    size = 4 * lines * words
    size_text = f"{size // 1024} KiB" if size >= 1024 else f"{size} B"
    text = f"{size_text}: {lines} lines of {words} word{'s' if words > 1 else ''}"
    return text if stream == "stream" else f"{text}, flash {flash}"


def main():
    results = {}
    for path in sys.argv[1:]:
        with open(path) as file:
            for line in file:
                match = LINE.search(line)
                if not match:
                    continue
                lines, words, stream, name, where = match.group(1, 2, 3, 4, 5)
                key = (int(lines), int(words), stream)
                hits, misses = int(match.group(9)), int(match.group(10))
                cell = results.setdefault(name, {}).setdefault(key, {})
                cell[where] = float(match.group(8))
                rate = 100.0 * hits / (hits + misses) if hits + misses else None
                if "rate" in cell and cell["rate"] != rate:
                    sys.exit(f"{name}, {key}: the hit rate differs between places")
                cell["rate"] = rate

    def order(key):
        lines, words, stream = key
        return (lines != 0, stream != "stream" if lines else stream == "stream",
                4 * lines * words, words)

    for name in ("tight", "straight", "bigloop", "selfmod"):
        if name not in results:
            continue
        print(f"\n{name}: clocks per instruction\n")
        print("| Cache | RAM, no wait | RAM, 3 waits | Flash | Hit rate |")
        print("| ----- | ------------ | ------------ | ----- | -------- |")
        for key in sorted(results[name], key=order):
            cell = results[name][key]
            rate = "" if cell["rate"] is None else f"{cell['rate']:.1f}%"
            print(f"| {label(*key)} | {cell.get('ram0', 0):.2f} | {cell.get('ram3', 0):.2f} "
                  f"| {cell.get('xip', 0):.2f} | {rate} |")


if __name__ == "__main__":
    main()
