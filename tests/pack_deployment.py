"""Assemble a source-free deployment of one staged composition for native acceptance."""
import sys

from workspace import pack_deployment

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: pack_deployment.py SOURCE DESTINATION")
    pack_deployment(sys.argv[1], sys.argv[2])
