import re
import sys
import argparse
import datetime

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--detections", required=True)
parser.add_argument("--total", required=True)
parser.add_argument("--file-id", required=True)
parser.add_argument("--scan-type", required=True, choices=["binary", "zip"])
args = parser.parse_args()

detections = int(args.detections)
total = int(args.total)
date = datetime.date.today().isoformat()
report_url = f"https://www.virustotal.com/gui/file/{args.file_id}"
scan_label = "App" if args.scan_type == "binary" else "Zip (fallback)"

color = "brightgreen" if detections == 0 else ("orange" if detections <= 3 else "red")
badge = f"[![VirusTotal](https://img.shields.io/badge/VirusTotal-{detections}%2F{total}_detections-{color})]({report_url})"

new_row = f"| {args.tag} | {date} | {detections} / {total} | {scan_label} | [View report]({report_url}) |"

with open("README.md", "r") as f:
    content = f.read()

pattern = re.compile(
    r"<!-- VIRUSTOTAL:START -->.*?<!-- VIRUSTOTAL:END -->",
    re.DOTALL
)

existing_block = pattern.search(content)
existing_rows = []
if existing_block:
    rows = re.findall(r"^\|.*\|$", existing_block.group(0), re.MULTILINE)
    existing_rows = [r for r in rows if not r.startswith("| Release") and not r.startswith("|---")]

all_rows = [new_row] + existing_rows
all_rows = all_rows[:3]

table = "\n".join([
    "| Release | Scan Date | Detections | Scanned | Report |",
    "|---|---|---|---|---|",
    *all_rows
])

new_block = f"<!-- VIRUSTOTAL:START -->\n{badge}\n\n{table}\n<!-- VIRUSTOTAL:END -->"

if existing_block:
    content = pattern.sub(new_block, content)
else:
    sys.exit("VIRUSTOTAL markers not found in README.md")

with open("README.md", "w") as f:
    f.write(content)
