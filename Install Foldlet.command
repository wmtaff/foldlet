#!/bin/bash
# Double-click this file (from the downloaded/unzipped repo) to build and install Foldlet.
cd "$(dirname "$0")"
bash ./install.sh
echo
read -n 1 -s -r -p "Press any key to close this window."
