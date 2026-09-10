/// Historical name for the shared platform storage rule, kept because the
/// diagnostics writers are documented and discussed under it. The rule itself
/// now lives in `AppleStorageRoot` so every durable writer shares one copy.
typealias DiagnosticsStorageRoot = AppleStorageRoot
