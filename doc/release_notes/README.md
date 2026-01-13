# Release Notes

This directory contains detailed release notes for OraDBA AutoUpgrade extension.

## Current Release

- [v0.3.0](v0.3.0.md) - 2026-01-12

## Release History

| Version             | Date       | Type          | Description                                                                    |
|---------------------|------------|---------------|--------------------------------------------------------------------------------|
| [v0.3.0](v0.3.0.md) | 2026-01-12 | Minor Release | Development workflow enhancements, synchronized with oradba_extension template |
| v0.2.0              | 2026-01-07 | Minor Release | Checksum exclusion support                                                     |

## Release Types

- **Major Release (X.0.0)**: Breaking changes, significant new features
- **Minor Release (0.X.0)**: New features, non-breaking changes
- **Patch Release (0.0.X)**: Bug fixes, minor improvements

## Documentation

For detailed information about each release:

1. Navigate to the specific version file (e.g., `v0.3.0.md`)
2. Review the changelog in [CHANGELOG.md](../../CHANGELOG.md)
3. Check the git tags: `git tag -l`

## Creating a Release

To create a new release:

1. Update [VERSION](../../VERSION) file
2. Update [CHANGELOG.md](../../CHANGELOG.md)
3. Create release document in this directory
4. Create git tag: `make tag`
5. Push tag: `git push origin v<VERSION>`
