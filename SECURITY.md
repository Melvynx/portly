# Security policy

## Supported versions

Security fixes are provided for the latest published Portly release.

## Report a vulnerability

Do not open a public issue for a security vulnerability. Email `melvyn@melvynx.com` with:

- the affected version;
- clear reproduction steps;
- the expected and observed behavior;
- the practical impact;
- any suggested mitigation.

You should receive an acknowledgment within 72 hours. Please allow time for a fix and coordinated disclosure before publishing details.

## Security model

Portly can start and stop local processes. Its control API therefore binds only to `127.0.0.1`. Changes that expose the API to the network or execute untrusted commands require explicit security review.
