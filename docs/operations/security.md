# Install-folder security

Before it uses its install folder, the agent checks and secures the root and the `logs`, `install`, `staging`, and `current` directories. Only SYSTEM and Administrators can access those folders; reading logs requires an elevated session.

If the root already exists but is untrusted, the agent moves it aside to `<name>.untrusted-<timestamp>-<id>` and creates a fresh secure root. It removes the old folder when possible; if cleanup fails, the folder remains quarantined for an administrator to delete. Link entries are removed rather than followed.

For a custom `-DscRoot`, specify a folder rather than a drive or network-share root, and ensure its parent folder does not let non-administrators delete or rename entries in it. The default `C:\ProgramData` parent meets this requirement.
