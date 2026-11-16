# Hermes Voice iOS

Before meaningful product or code changes, use the Markbase connection to list workspace `hermes-voice-ios` and read `_markbase.md`, `Architecture.md`, `PRD.md`, `Tasks.md` and relevant recent decisions. The workspace is the source of truth for specifications and rationale; verify implementation claims against the current Git branch.

After a meaningful change, update affected Markbase docs and add a dated changelog entry before handing back. Record actual validation and distinguish simulator results from physical iPhone/CarPlay evidence. Keep internal workspace documents, drafts, credentials, machine-specific configuration and routine QA screenshot files out of Git. Use hosted screenshot links for QA; the curated, synthetic public README gallery in docs/images is explicitly requested and may be committed. Do not replace human-authored decisions with inferred code behavior.

Documentation updates are tied to meaningful project changes; there is no recurring AI polling task. Keep Markbase's repository status consistent with published commits and distinguish unmerged work. This does not authorize publishing uncommitted work. If Markbase is unavailable, report the failed sync and preserve a private handoff outside the repo.

Run backend checks with `(cd server && ../.venv/bin/python -m unittest discover -v)`. Generate the Xcode project from `project.yml` after copying `Local.xcconfig.example` to ignored `Local.xcconfig`. Preserve the one shared voice session for CallKit, iPhone and CarPlay. Do not modify update-managed Hermes core. Obtain any permission still required for external actions; a call is not itself approval.
