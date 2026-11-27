# Pre-migration backups (HANDOFF §17)

Before each migration, the tables it changes are copied into the private `backup` schema
(no grants to `anon`/`authenticated`, not exposed by the API) as `backup.<table>_<yyyymmdd>_<migration>`.
The nightly `cleanup_retention()` job drops backup tables older than 14 days.

To restore after a rollback script: `insert into public.<table> select * from backup.<table>_<yyyymmdd>_<NNNN>;`
(adjust columns if the rollback changed them).

| Before | Tables copied |
|---|---|
| 0002 | suggestions, categories, votes |
| 0003 | catalog (read by the new functions; no existing table is altered) |
| 0004 | owner_secret, secrets |
| 0005 | suggestions |
| 0006 | none altered (new objects only); catalog_votes copied for the deletion function |
| 0008 | secrets (a row is added: the Site Stats token hash) |
