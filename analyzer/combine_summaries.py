#!/usr/bin/env python3
"""
Script to combine all summary_metrics CSV files from different runs into a single file.
"""

import os
import pandas as pd
from pathlib import Path
import re


def parse_directory_name(dir_name):
    """
    Parse directory name to extract model, config version, threshold, and run number.
    Example: anthropic-claude-haiku-4.5_input_const_v2_0.5_run1
    Returns: (model, config_version, threshold, run_number)
    """
    # Pattern to match: model_config_threshold_runX
    pattern = r'^(.+?)_(input_const_v\d+)_(\d+\.\d+)_run(\d+)$'
    match = re.match(pattern, dir_name)
    
    if match:
        model = match.group(1)
        config_version = match.group(2)
        threshold = match.group(3)
        run_number = match.group(4)
        return model, config_version, threshold, run_number
    else:
        # Fallback if pattern doesn't match
        return dir_name, '', '', ''


def find_summary_files(output_dir):
    """
    Find all summary_metrics_*.csv files in subdirectories.
    Returns list of tuples: (file_path, model, config_version, threshold, run_number)
    """
    summary_files = []
    output_path = Path(output_dir)
    
    for subdir in output_path.iterdir():
        if subdir.is_dir():
            summary_dir = subdir / 'summary'
            if summary_dir.exists():
                # Find all summary_metrics_*.csv files
                for csv_file in summary_dir.glob('summary_metrics_*.csv'):
                    model, config_version, threshold, run_number = parse_directory_name(subdir.name)
                    summary_files.append((csv_file, model, config_version, threshold, run_number))
    
    return summary_files


def combine_summaries(output_dir, output_file='combined_summaries.csv'):
    """
    Combine all summary files into a single CSV file.
    """
    summary_files = find_summary_files(output_dir)
    
    if not summary_files:
        print("No summary files found!")
        return
    
    print(f"Found {len(summary_files)} summary files")
    
    all_data = []
    
    for file_path, model, config_version, threshold, run_number in summary_files:
        print(f"Processing: {file_path.name} from {model} run {run_number}")
        
        # Read the CSV file
        df = pd.read_csv(file_path, index_col=0)
        
        # Add identifier columns
        df['model'] = model
        df['config_version'] = config_version
        df['threshold'] = threshold
        df['run_number'] = int(run_number) if run_number else 0
        
        # Reset index to make metric names a column
        df = df.reset_index()
        df = df.rename(columns={'index': 'metric'})
        
        all_data.append(df)
    
    # Combine all dataframes
    combined_df = pd.concat(all_data, ignore_index=True)
    
    # Reorder columns to put identifiers first
    cols = ['model', 'config_version', 'threshold', 'run_number', 'metric', 'mean', 'min', 'max', 'std', 'median']
    combined_df = combined_df[cols]
    
    # Sort by model, run_number, and metric
    combined_df = combined_df.sort_values(['model', 'run_number', 'metric'])
    
    # Save to output file
    output_path = Path(output_dir) / output_file
    combined_df.to_csv(output_path, index=False)
    
    print(f"\n✓ Combined summary saved to: {output_path}")
    print(f"Total rows: {len(combined_df)}")
    print(f"\nModels found: {combined_df['model'].unique().tolist()}")
    print(f"Runs per model: {combined_df.groupby('model')['run_number'].nunique().to_dict()}")


if __name__ == '__main__':
    # Set the output directory
    script_dir = Path(__file__).parent
    output_dir = script_dir / 'output'
    
    if not output_dir.exists():
        print(f"Error: Output directory not found: {output_dir}")
        exit(1)
    
    print(f"Scanning directory: {output_dir}\n")
    combine_summaries(output_dir)
