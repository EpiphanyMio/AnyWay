# AnyWay development rules

- Before modifying the repository, fetch and synchronize with the latest `origin/main`. Preserve any uncommitted work before merging remote changes.
- This is one product with two platform implementations: `mac/` and `windows/`. For a user-facing feature or behavior change, inspect both and implement the equivalent behavior on both unless the feature is platform-specific.
- The single product version is the root `VERSION` file. Mac app/pkg, Windows installer, and both Android companion builds must derive their version from it. Never bump only one platform.
- Keep the JSON configuration schema compatible across platforms (`schemaVersion: 1`); update both readers/writers and both sets of tests when the schema changes.
- Preserve platform-specific device bridges inside their platform directories. Shared documentation and version policy stay at the repository root.
- For a release, build/test both platforms, then publish both platform artifacts under the same version tag. Do not describe a release as cross-platform until both artifacts exist.
