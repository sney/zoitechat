#!/usr/bin/env python3
import sys
import urllib.request
from pathlib import Path

URL = "https://raw.githubusercontent.com/publicsuffix/list/main/public_suffix_list.dat"


def parse_rules(text: str):
    rules = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("//"):
            continue
        if " " in line or "\t" in line:
            line = line.split()[0]
        rules.append(line.lower())
    return sorted(set(rules))


def emit_header(path: str, rules):
    with open(path, "w", encoding="utf-8", newline="\n") as out:
        out.write("#pragma once\n")
        out.write("static const char * const public_suffix_rules[] = {\n")
        for rule in rules:
            escaped = rule.replace("\\", "\\\\").replace('"', '\\"')
            out.write(f'\t"{escaped}",\n')
        out.write("};\n")
        out.write(
            "static const unsigned int public_suffix_rules_len = sizeof(public_suffix_rules) / sizeof(public_suffix_rules[0]);\n"
        )


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: gen-public-suffix.py <output>")
    output = Path(sys.argv[1])
    fallback = Path(__file__).with_name("public_suffix_data.h")
    try:
        with urllib.request.urlopen(URL, timeout=30) as resp:
            data = resp.read().decode("utf-8")
        rules = parse_rules(data)
        emit_header(str(output), rules)
    except Exception:
        if not fallback.exists():
            raise
        output.write_bytes(fallback.read_bytes())


if __name__ == "__main__":
    main()
