import sys
import xml.etree.ElementTree as ET

source_file, output_file = sys.argv[1:3]
source = ET.parse(source_file).getroot()
output = ET.parse(output_file).getroot()

if source.tag != output.tag:
    raise SystemExit("The XML files have different root elements")

for child in list(source):
    matches = output.findall(child.tag)
    if not matches:
        output.append(child)
        continue

    target = matches[0]
    target.attrib.update(child.attrib)
    for setting in child:
        for existing in target.findall(setting.tag):
            target.remove(existing)
        target.append(setting)

    for duplicate in matches[1:]:
        output.remove(duplicate)

ET.indent(output, space="  ")
ET.ElementTree(output).write(output_file, encoding="utf-8", xml_declaration=True)