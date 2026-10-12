# odb_autoupgrade Documentation

Current version: see [`../VERSION`](../VERSION) | [Changelog](../CHANGELOG.md)
Latest release: [v0.6.0](release_notes/v0.6.0.md)

Oracle AutoUpgrade patching tooling - runs standalone or as an OraDBA extension.

## Guides

- [Installation](installation.md) - standalone install, OraDBA extension install, offline install
- [Configuration](configuration.md) - precedence levels, file security, all AU_* variables, au_patch.cfg keys
- [Patch Profiles](patch-profiles.md) - profile format, shipped profiles, pinning, verification, CPU-test workflow
- [Oracle Home Management](oracle-home.md) - create_home, edition, OS groups, gold image paths, home naming
- [Keystore and JAR](keystore-and-jar.md) - MOS keystore lifecycle, auto-login modes, JAR update flow
- [Log Cleanup](log-cleanup.md) - safe cleanup of AutoUpgrade global_log_dir
- [Proxy and Truststore](proxy-and-truststore.md) - TLS inspection, proxy config, required network endpoints

## Reference

- [Reference](reference.md) - all scripts, options and environment variables

## Design and Development

- [Design](design.md) - Phase 2 architecture, decisions, and work packages
- [Development](development.md) - contributing, testing, build

## Migration

- [Upgrade 0.6.0](upgrade-0.6.0.md) - migration from 0.5.0 and legacy layout

## Release Notes

- [v0.6.0](release_notes/v0.6.0.md) - Phase 2 consolidation: profiles, unified template, keystore lifecycle,
  JAR update, log cleanup, gold image tooling, home generation
- [v0.5.0](release_notes/v0.5.0.md) - proxy and truststore, connectivity check, au_ prefix rename
- [v0.4.0](release_notes/v0.4.0.md) - extension hook scaffolding
- [v0.3.1](release_notes/v0.3.1.md) - enhanced release workflow
- [v0.3.0](release_notes/v0.3.0.md) - development workflow
- [All release notes](release_notes/)
