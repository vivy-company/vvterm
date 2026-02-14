# Contributing to VVTerm

Thanks for your interest in contributing to VVTerm.

## Code of Conduct

By participating in this project, you agree to follow `CODE_OF_CONDUCT.md`.

## Before You Start

1. Search existing issues and pull requests to avoid duplicate work.
2. For large changes, open an issue first to align on approach and scope.
3. Keep pull requests focused and small when possible.

## Development Setup

Requirements:

- Xcode 16.0+
- Zig (for building Ghostty): `brew install zig`

Setup:

```bash
git clone https://github.com/vivy-company/vvterm.git
cd vvterm
./scripts/build.sh all
open VVTerm.xcodeproj
```

## Pull Request Guidelines

1. Create a branch from `main`.
2. Make your changes with clear commit messages.
3. Run relevant checks/tests locally before opening a PR.
4. Include screenshots or recordings for UI changes.
5. Include clear validation notes for networking/terminal behavior changes.

## CLA Requirement

This repository requires signing the Contributor License Agreement before a PR can be merged.

1. Read `CLA.md`.
2. Comment on your pull request with the exact text below:

```text
I have read the CLA Document and I hereby sign the CLA
```

CLA checks are enforced by the repository bot configuration in `.clabot`.

## License

By submitting contributions, you agree that your contributions may be distributed under the project's dual-license model:

- Source code license: `LICENSE` (GPL-3.0)
- Official App Store binary terms: `LICENSE-APPSTORE.md`
