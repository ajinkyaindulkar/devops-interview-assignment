#!/usr/bin/env python3
"""
camera_discovery.py — ONVIF Camera Discovery Tool

Reads an ONVIF WS-Discovery ProbeMatches XML response, extracts camera
metadata from each ProbeMatch element, and outputs a JSON array to stdout.

Typical WS-Discovery XML structure:
  <SOAP-ENV:Envelope>
    <SOAP-ENV:Body>
      <d:ProbeMatches>
        <d:ProbeMatch>
          <wsa:EndpointReference>
            <wsa:Address>urn:uuid:<uuid></wsa:Address>
          </wsa:EndpointReference>
          <d:Scopes>
            onvif://www.onvif.org/hardware/<model>
            onvif://www.onvif.org/name/<name>
            onvif://www.onvif.org/location/<location>
          </d:Scopes>
          <d:XAddrs>http://<ip>/onvif/device_service</d:XAddrs>
        </d:ProbeMatch>
      </d:ProbeMatches>
    </SOAP-ENV:Body>
  </SOAP-ENV:Envelope>

Example output:
[
  {
    "uuid": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "model": "P3265-LVE",
    "name": "AXIS P3265-LVE",
    "location": "LoadingDockA",
    "service_url": "http://10.50.20.101:80/onvif/device_service",
    "ip": "10.50.20.101"
  }
]
"""

import argparse
import json
import signal
import sys
import xml.etree.ElementTree as ET
from urllib.parse import unquote, urlparse

# ---------------------------------------------------------------------------
# ONVIF WS-Discovery XML namespace map.
# ElementTree requires fully-qualified namespace URIs in Clark notation
# ({uri}localname) or via a prefix map passed to findall/find.
# These are the three namespaces present in every WS-Discovery response.
# ---------------------------------------------------------------------------
NAMESPACES = {
    "soap": "http://www.w3.org/2003/05/soap-envelope",
    "wsa":  "http://schemas.xmlsoap.org/ws/2004/08/addressing",
    "d":    "http://schemas.xmlsoap.org/ws/2005/04/discovery",
}

# ONVIF scope URI prefixes — cameras publish metadata as scoped URIs
SCOPE_HARDWARE = "onvif://www.onvif.org/hardware/"
SCOPE_NAME     = "onvif://www.onvif.org/name/"
SCOPE_LOCATION = "onvif://www.onvif.org/location/"


def parse_args():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(
        description="Parse an ONVIF WS-Discovery XML response and output camera list as JSON.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--input",
        metavar="FILE",
        default=None,
        help="Path to XML file containing WS-Discovery response. Reads from stdin if omitted.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=5.0,
        metavar="SECONDS",
        help="Seconds to wait for stdin input before giving up (default: 5.0). "
             "Has no effect when --input FILE is provided.",
    )
    return parser.parse_args()


def _extract_scope_value(scopes_text, prefix):
    """
    Extract the value after a given ONVIF scope prefix from whitespace-separated scopes.

    Scope values are URL-encoded (e.g. 'AXIS%%20P3265-LVE' → 'AXIS P3265-LVE').
    Returns None if the prefix is not present.
    """
    for scope in scopes_text.split():
        if scope.startswith(prefix):
            return unquote(scope[len(prefix):])
    return None


def _extract_ip(service_url):
    """
    Parse the hostname/IP from a service URL like http://10.50.20.101:80/onvif/device_service.
    Returns None if the URL is malformed.
    """
    try:
        return urlparse(service_url).hostname
    except Exception:
        return None


def parse_onvif_response(xml_content):
    """
    Parse ONVIF WS-Discovery XML and return a list of camera dicts.

    Malformed ProbeMatch elements are skipped with a warning on stderr so a
    single bad camera does not prevent the rest from being returned.
    """
    cameras = []

    # Parse the XML document — raises ET.ParseError on malformed XML
    try:
        root = ET.fromstring(xml_content)
    except ET.ParseError as exc:
        print(f"[ERROR] XML parse error: {exc}", file=sys.stderr)
        return cameras

    probe_matches = root.findall(".//d:ProbeMatch", NAMESPACES)

    if not probe_matches:
        print("[WARN] No ProbeMatch elements found in the response.", file=sys.stderr)
        return cameras

    for match in probe_matches:
        try:
            # ------------------------------------------------------------------
            # UUID — from EndpointReference/Address, strip the "urn:uuid:" prefix
            # ------------------------------------------------------------------
            addr_el = match.find("wsa:EndpointReference/wsa:Address", NAMESPACES)
            raw_addr = (addr_el.text or "").strip() if addr_el is not None else ""
            uuid = raw_addr.replace("urn:uuid:", "") or None

            # ------------------------------------------------------------------
            # Scopes — space-separated URIs encoding hardware, name, location
            # ------------------------------------------------------------------
            scopes_el = match.find("d:Scopes", NAMESPACES)
            scopes_text = (scopes_el.text or "").strip() if scopes_el is not None else ""

            model    = _extract_scope_value(scopes_text, SCOPE_HARDWARE)
            name     = _extract_scope_value(scopes_text, SCOPE_NAME)
            location = _extract_scope_value(scopes_text, SCOPE_LOCATION)

            # ------------------------------------------------------------------
            # Service URL — XAddrs may contain multiple space-separated URLs;
            # use the first one (typically the primary device service endpoint)
            # ------------------------------------------------------------------
            xaddrs_el = match.find("d:XAddrs", NAMESPACES)
            service_url = None
            if xaddrs_el is not None and xaddrs_el.text:
                service_url = xaddrs_el.text.strip().split()[0]

            ip = _extract_ip(service_url) if service_url else None

            cameras.append({
                "uuid":        uuid,
                "model":       model,
                "name":        name,
                "location":    location,
                "service_url": service_url,
                "ip":          ip,
            })

        except Exception as exc:
            # Skip this ProbeMatch and continue — one bad entry should not
            # prevent the remaining cameras from being discovered.
            print(f"[WARN] Skipping malformed ProbeMatch: {exc}", file=sys.stderr)

    return cameras


def _read_stdin_with_timeout(timeout_seconds):
    """
    Read all of stdin, raising TimeoutError if no data arrives within timeout.
    Uses SIGALRM (Unix only). On Windows, the timeout is silently ignored.
    """
    try:
        def _handler(signum, frame):
            raise TimeoutError(
                f"Timed out after {timeout_seconds}s waiting for stdin input."
            )
        signal.signal(signal.SIGALRM, _handler)
        signal.alarm(int(timeout_seconds))
        try:
            return sys.stdin.read()
        finally:
            signal.alarm(0)  # Cancel the alarm once read completes
    except AttributeError:
        # signal.SIGALRM is not available on Windows; read without timeout
        return sys.stdin.read()


def main():
    args = parse_args()

    # -------------------------------------------------------------------------
    # Read XML input from file or stdin
    # -------------------------------------------------------------------------
    try:
        if args.input:
            with open(args.input, "r", encoding="utf-8") as fh:
                xml_content = fh.read()
        else:
            xml_content = _read_stdin_with_timeout(args.timeout)
    except FileNotFoundError:
        print(f"[ERROR] Input file not found: {args.input}", file=sys.stderr)
        sys.exit(1)
    except TimeoutError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        sys.exit(1)
    except OSError as exc:
        print(f"[ERROR] Failed to read input: {exc}", file=sys.stderr)
        sys.exit(1)

    if not xml_content.strip():
        print("[ERROR] Input is empty.", file=sys.stderr)
        sys.exit(1)

    # -------------------------------------------------------------------------
    # Parse and output
    # -------------------------------------------------------------------------
    cameras = parse_onvif_response(xml_content)

    # Always output valid JSON — even an empty list is valid and parseable
    # by downstream consumers (provisioning scripts, dashboards).
    print(json.dumps(cameras, indent=2))


if __name__ == "__main__":
    main()
