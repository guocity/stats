#!/usr/bin/env python3
import re
import sys
import os

def find_config_blocks(text):
    blocks = []
    idx = 0
    while True:
        # Search for XCBuildConfiguration blocks (Debug or Release)
        match = re.search(r"/\* (Debug|Release) \*/\s*=\s*\{", text[idx:])
        if not match:
            break
        start_pos = idx + match.start()
        # Find the matching closing brace for the config block
        brace_count = 1
        curr = idx + match.end()
        while curr < len(text) and brace_count > 0:
            if text[curr] == '{':
                brace_count += 1
            elif text[curr] == '}':
                brace_count -= 1
            curr += 1
        blocks.append((start_pos, curr))
        idx = curr
    return blocks

def main():
    path = "Stats.xcodeproj/project.pbxproj"
    if not os.path.exists(path):
        print(f"Error: Run this script from the repository root. '{path}' not found.")
        sys.exit(1)

    with open(path, "r") as f:
        content = f.read()

    blocks = find_config_blocks(content)
    
    # We want to identify the current version and update it.
    # We will find the blocks belonging to the main target: eu.exelban.Stats
    main_target_blocks = []
    current_version = None
    
    for start, end in blocks:
        block_text = content[start:end]
        if "PRODUCT_BUNDLE_IDENTIFIER = eu.exelban.Stats;" in block_text:
            main_target_blocks.append((start, end))
            # Find the version in this block
            match = re.search(r"MARKETING_VERSION = (\d+)\.(\d+)\.(\d+);", block_text)
            if match:
                current_version = f"{match.group(1)}.{match.group(2)}.{match.group(3)}"

    if not main_target_blocks or not current_version:
        print("Error: Could not find build settings for bundle eu.exelban.Stats with a valid MARKETING_VERSION.")
        sys.exit(1)

    # Calculate new version
    major, minor, patch = map(int, current_version.split("."))
    new_version = f"{major}.{minor}.{patch+1}"

    # Reconstruct the file contents, updating the MARKETING_VERSION line inside only the main target blocks
    new_content = ""
    last_idx = 0
    for start, end in main_target_blocks:
        new_content += content[last_idx:start]
        block_text = content[start:end]
        updated_block = block_text.replace(f"MARKETING_VERSION = {current_version};", f"MARKETING_VERSION = {new_version};")
        new_content += updated_block
        last_idx = end
    new_content += content[last_idx:]

    with open(path, "w") as f:
        f.write(new_content)

    print(f"Successfully incremented patch version from {current_version} to {new_version}")

if __name__ == "__main__":
    main()
