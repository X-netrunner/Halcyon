"""Birthday import: python3 tests/test_birthdays.py   (quickshell/island/scripts/gcal.py parsers)"""
import importlib.util, os, sys

here = os.path.dirname(os.path.abspath(__file__))
sys.argv = ["gcal.py"]
spec = importlib.util.spec_from_file_location("gcal", os.path.join(here, "..", "quickshell", "island", "scripts", "gcal.py"))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)

DATES = [("1998-10-14", (1998, 10, 14)), ("--10-14", (None, 10, 14)), ("19981014", (1998, 10, 14)),
         ("10/14/1998", (1998, 10, 14)), ("14/10/1998", (1998, 10, 14)), ("10-14", (None, 10, 14)),
         ("Oct 14, 1998", (1998, 10, 14)), ("14 October", (None, 10, 14)), ("--02-29", (None, 2, 29)),
         ("1850-05-05", (None, 5, 5)),                      # a year before 1900 is dropped, the day stays
         ("02/30", None), ("2026-02-31", None), ("--04-31", None), ("2026-13-01", None), ("", None), ("garbage", None)]
VCF = "BEGIN:VCARD\nVERSION:3.0\nFN:Sarah Lee\nBDAY:1998-10-14\nEND:VCARD\nBEGIN:VCARD\nVERSION:4.0\nFN:Tom\nBDAY:--03-09\nEND:VCARD\nBEGIN:VCARD\nFN:NoBday\nEND:VCARD\n"
CSV = "First Name,Last Name,Birthday\nSarah,Lee,1998-10-14\nTom,,--03-09\nNoB,x,\n"
WANT = [{"name": "Sarah Lee", "year": 1998, "month": 10, "day": 14}, {"name": "Tom", "year": None, "month": 3, "day": 9}]

bad = 0
for raw, want in DATES:
    got = g.parse_bday_date_any(raw)
    if got != want: bad += 1; print(f"FAIL date {raw!r}: {got} (want {want})")
for label, got in (("vcf", g.parse_vcf(VCF)), ("csv", g.parse_contacts_csv(CSV))):
    if got != WANT: bad += 1; print(f"FAIL {label}: {got}")
print("ok" if not bad else f"{bad} failed")
sys.exit(1 if bad else 0)
