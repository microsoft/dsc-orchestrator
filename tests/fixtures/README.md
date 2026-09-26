# Test fixtures

`dsc-orchestrator.config.json` and `fragments/baseline.dsc.yaml` exercise the v1 input and fragment contract. Other fixtures provide representative wrapped resources, bootstrap child-process fakes, and local test data.

The bootstrap harness shadows scheduled-task commands and guards module-directory operations so tests do not register machine-wide tasks or modify the host's AllUsers module path.
