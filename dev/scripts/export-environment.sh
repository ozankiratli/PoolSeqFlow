
#!/usr/bin/env bash
# Export the active PoolSeqFlow conda environment to install/environment.yml
# Usage: conda activate PoolSeqFlow && bash export_environment.sh
 
set -e
 
OUTPUT="install/environment.yml"
 
conda env export --name PoolSeqFlow > "$OUTPUT"
 
# Replace the hardcoded prefix path with a portable $HOME-relative path
sed -i "s|/home/[^/]*/|$HOME/|g" "$OUTPUT"
 
echo "Exported to $OUTPUT"
