"""Convert a flat little-endian binary to $readmemh words: bin2hex.py in.bin out.hex"""

import sys

data = open(sys.argv[1], "rb").read()
data += b"\0" * (-len(data) % 4)
with open(sys.argv[2], "w") as out:
    for i in range(0, len(data), 4):
        out.write(f"{int.from_bytes(data[i:i + 4], 'little'):08x}\n")
