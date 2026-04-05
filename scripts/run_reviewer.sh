#!/bin/bash
# run_reviewer.sh — v2 compatibility shim for Stallions v3.
# Delegates to run_agent.sh with role=reviewer.
exec "$(dirname "$0")/run_agent.sh" --role reviewer "$@"
