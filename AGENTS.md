# Working on Luna

Before changing behavior, read the relevant entries in [docs/llm-changelog.md](docs/llm-changelog.md) for implementation decisions, regressions, and verification history.

For every completed change, add a dated entry to that log with the request, resulting behavior, relevant files, verification results, and remaining limitations. Keep newest entries first and distinguish implementation from release status. Record follow-up corrections explicitly so agents can backtrack without reconstructing commits. Update the entry when release verification finishes.

When shipping, follow [docs/releasing.md](docs/releasing.md). Keep user-facing release highlights in `CHANGELOG.md`; the LLM log carries technical context and reasoning.

After every update, build and open the updated Luna app for the user to review before reporting completion. Preserve existing notes when relaunching, and confirm that the opened app is the build from the current worktree.
