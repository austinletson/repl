#!/usr/bin/env bash

# Define the paths
IN_DIR="test"
EXPECTED_DIR="test"
# CI sets this from the Lean version's Mathlib tag availability.
RUN_MATHLIB="${RUN_MATHLIB:-0}"

lake build

# ignore locale to ensure test `bla` runs before `bla2`
export LC_COLLATE=C

if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    mapfile -t input_files < <(git ls-files "$IN_DIR" | awk -v dir="$IN_DIR/" 'index($0, dir) == 1 && substr($0, length(dir) + 1) !~ /\// && $0 ~ /\.in$/ { print }' | sort)
else
    mapfile -t input_files < <(find "$IN_DIR" -maxdepth 1 -name '*.in' | sort)
fi

# Iterate over each tracked .in file in the test directory
for infile in "${input_files[@]}"; do
    # Extract the base filename without the extension
    base=$(basename "$infile" .in)

    # Define the path for the expected output file
    expectedfile="$EXPECTED_DIR/$base.expected.out"

    # Check if the expected output file exists
    if [[ ! -f $expectedfile ]]; then
        echo "Expected output file $expectedfile does not exist. Skipping $infile."
        continue
    fi

    # Run the command and store its output in a temporary file
    tmpfile=$(mktemp)
    .lake/build/bin/repl < "$infile" > "$tmpfile" 2>&1

    # Compare the output with the expected output
    if diff "$tmpfile" "$expectedfile"; then
        echo "$base: PASSED"
        # Remove the temporary file
        rm "$tmpfile"
    else
        echo "$base: FAILED"
        # Rename the temporary file instead of removing it
        mv "$tmpfile" "${expectedfile/.expected.out/.produced.out}"
        exit 1
    fi

done

if [[ "$RUN_MATHLIB" == "1" ]]; then
    rm -f test/Mathlib/lean-toolchain
    cp lean-toolchain test/Mathlib/
    cd test/Mathlib/ && ./test.sh
else
    echo "Mathlib tests skipped. Set RUN_MATHLIB=1 to run them."
fi
