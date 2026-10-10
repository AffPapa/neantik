"""Check every SPDX package's license text against Chromium's deduplicated HTML."""
from html.parser import HTMLParser


class CreditsParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.entries = []
        self.title = self.pre = False

    def handle_starttag(self, tag, attrs):
        if tag == "div" and ("class", "product") in attrs:
            self.entries.append({"name": "", "text": ""})
        if tag == "span" and ("class", "title") in attrs:
            self.title = True
        if tag == "pre":
            self.pre = True

    def handle_endtag(self, tag):
        if tag == "span":
            self.title = False
        if tag == "pre":
            self.pre = False

    def handle_data(self, data):
        if self.entries:
            if self.title:
                self.entries[-1]["name"] += data
            if self.pre:
                self.entries[-1]["text"] += data


def verify_coverage(credits, spdx):
    parser = CreditsParser()
    parser.feed(credits)
    licenses = {}
    for item in spdx["hasExtractedLicensingInfos"]:
        identifier, text = item["licenseId"], item["extractedText"].strip()
        if identifier in licenses or not text:
            raise ValueError("Duplicate or empty SPDX license")
        licenses[identifier] = text
    covered_entries, covered_licenses = set(), set()
    for package in spdx["packages"]:
        name = package["name"]
        # Chromium's HTML template names its own BSD notice this way.
        name = "The Chromium Project" if name == "Chromium" else name
        identifier = package["licenseConcluded"]
        text = licenses.get(identifier)
        if not text:
            raise ValueError("SPDX package has no extracted license")
        matches = [i for i, entry in enumerate(parser.entries)
                   if entry["name"].casefold() == name.casefold()
                   and text in entry["text"].strip()]
        if not matches:
            raise ValueError("SPDX package license is absent from HTML credits")
        covered_entries.update(matches)
        covered_licenses.add(identifier)
    if len(covered_entries) != len(parser.entries) or covered_licenses != licenses.keys():
        raise ValueError("HTML and SPDX contain unmatched license records")
    return len(parser.entries)
