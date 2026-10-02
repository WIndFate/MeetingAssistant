#!/bin/bash
# Compiles the pure-logic sources with Checks/MeetingChecks.swift and runs them.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d /tmp/meeting-assistant-checks.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT

src="$repo_root/MeetingAssistant"
xcrun swiftc \
    -module-cache-path "$work_dir/module-cache" \
    "$src/Models/TranscriptionLanguage.swift" \
    "$src/Services/MeetingCallDetector.swift" \
    "$src/Services/MeetingKnowledge.swift" \
    "$src/Services/MeetingPrompts.swift" \
    "$src/Services/OpenAIChatClient.swift" \
    "$src/Services/TranscriptAssembler.swift" \
    "$repo_root/Checks/MeetingChecks.swift" \
    -o "$work_dir/checks"
"$work_dir/checks"
