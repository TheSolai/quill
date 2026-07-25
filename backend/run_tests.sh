#!/bin/bash
# Quill test runner. Usage: ./run_tests.sh
cd "$(dirname "$0")"
echo "=================================="
echo "  Quill Backend Test Suite"
echo "=================================="
python3 -m pytest tests/test_server.py -v
