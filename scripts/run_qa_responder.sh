#!/bin/bash
# run_qa_responder.sh — v2 compatibility shim for Stallions v3.
# Delegates to run_agent.sh with role=qa.
# The --once flag is passed through transparently.
exec "$(dirname "$0")/run_agent.sh" --role qa "$@"
