# Log

Append-only record of every operation. One entry per operation, consistent
prefix so it stays greppable:

```bash
grep "^## \[" wiki/log.md
```

## [2026-01-15] setup | Vault created
- Seeded the three example pages, the index, and this log.
- Replace the examples with real content and delete them.
