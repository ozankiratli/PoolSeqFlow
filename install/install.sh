#!/bin/bash

echo "Installing PoolSeqFlow pipeline..."

# Check conda environment
if ! conda env list | grep -q "PoolSeqFlow"; then
    echo "Creating PoolSeqFlow conda environment..."
    conda env create -f environment.yml
else
    echo "PoolSeqFlow conda environment already exists"
fi

# Activate environment
conda activate PoolSeqFlow