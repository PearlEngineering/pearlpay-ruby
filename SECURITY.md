# Security Policy

## Reporting a vulnerability

Email **security@pearlpay.io**. Do not open public issues for security reports.
We aim to acknowledge reports within 2 business days.

## Supported versions

The latest minor release receives security fixes.

## Design notes for reviewers

- TLS certificate verification is always on (`VERIFY_PEER`); there is no toggle.
  Plain `http://` is accepted only for localhost development.
- Redirects are never followed; response bodies are capped at 10 MB; only
  `JSON.parse` is used on server data (no YAML, no Marshal, no constantizing).
- API keys and signing secrets are redacted from `inspect`/`to_s`, never appear
  in instrumentation events or exception messages, and are enforced by spec
  (`spec/unit/redaction_spec.rb`).
- Webhook signature verification uses `OpenSSL.fixed_length_secure_compare`
  with a length pre-check, and enforces a timestamp tolerance (default 300 s).
- Request signing nonces are single-use and regenerated per attempt.
