# Install-folder security

Before it uses its install folder, the agent checks and secures the root and the `logs`, `install`, `staging`, and `current` directories. Only SYSTEM and Administrators can access those folders; reading logs requires an elevated session.

If the root already exists but is untrusted, the agent secures it, removes its contents without following links, and records that it was reset. Link entries are removed rather than followed.

For a custom `-DscRoot`, its parent folder must not let non-administrators delete or rename entries in it. The default `C:\ProgramData` parent meets this requirement.
