# Contributing

1. Fork the repository and create a focused branch.
2. Run `./scripts/setup.sh`.
3. Make changes without adding broker data, credentials or personal files.
4. Run `./scripts/verify.sh`.
5. Open a pull request describing the user impact, validation and remaining
   limitations.

All contributions must preserve the simulation-only boundary. A change that
enables real-money execution will not be accepted.
