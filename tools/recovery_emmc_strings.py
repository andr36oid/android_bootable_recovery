import json
import re
import sys
import xml.etree.ElementTree as ET


def main():
    # Recovery has no Android resource loader; keep its new text in strings.xml.
    resources = ET.parse(sys.argv[1]).getroot()
    with open(sys.argv[2], "w") as out:
        out.write("#pragma once\n\nnamespace emmc_strings {\n")
        names = set()
        for entry in resources.findall("string"):
            name = entry.attrib["name"]
            if not re.fullmatch(r"[a-z][a-z0-9_]*", name) or name in names:
                raise ValueError(name)
            names.add(name)
            value = "".join(entry.itertext())
            out.write("inline constexpr char %s[] = %s;\n" % (name, json.dumps(value)))
        out.write("}\n")


if __name__ == "__main__":
    main()
