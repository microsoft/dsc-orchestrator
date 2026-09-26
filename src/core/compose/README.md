# Compose

`New-DSCv3PreparedFragments.ps1` reads a `dsc-orchestrator.config.json`, resolves fragment paths relative to that file, renders scalar parameters, validates each fragment, checks cross-fragment resource names and dependencies, and writes a prepared `configs/` tree plus an intermediate `manifest.json`.

The required input fields, optional group/role metadata and module list, token rules, and output manifest are documented in [the package format](../../../docs/package-format/README.md). The composer returns an object containing the configuration name/version, rendered configuration hash, output path, manifest path, and fragment/resource counts.

The renderer intentionally operates on YAML lines so whole-scalar `{{ Token }}` values remain intact until substitution. `Dsc.Prepare.Dependencies.psm1` loads `powershell-yaml` only when a fragment declares a top-level `metadata` block with dependency metadata.
