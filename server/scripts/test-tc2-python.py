#!/usr/bin/env python3
"""Test TC2 auth using the actual Python total-connect-client library."""
import sys

try:
    from total_connect_client.client import TotalConnectClient
except ImportError:
    print("Installing total-connect-client...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "total-connect-client", "--break-system-packages", "-q"])
    from total_connect_client.client import TotalConnectClient

username = sys.argv[1] if len(sys.argv) > 1 else None
password = sys.argv[2] if len(sys.argv) > 2 else None

if not username or not password:
    print("Usage: python3 test-tc2-python.py <username> <password>")
    sys.exit(1)

import logging
logging.basicConfig(level=logging.DEBUG)

try:
    client = TotalConnectClient(username, password, auto_bypass_battery=False)
    print("\n=== SUCCESS ===")
    print(f"Locations: {len(client.locations)}")
    for loc_id, loc in client.locations.items():
        print(f"  {loc_id}: {loc}")
except Exception as e:
    print(f"\n=== FAILED ===")
    print(f"Error: {e}")
