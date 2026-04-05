#!/bin/bash
# run_implementer.sh — v2 compatibility shim for Stallions v3.
# Delegates to run_agent.sh with role=implementer.
exec "$(dirname "$0")/run_agent.sh" --role implementer "$@"
