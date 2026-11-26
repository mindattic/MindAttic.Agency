# SQL Server 2025 Express fit for Prose and IdiotProof_History (MAT-T229)

Date: 2026-11-26

## Method and its limit

The container check was NOT possible. `docker version` showed a 20.10.23 client but the Docker
daemon was not running (no `docker_engine` pipe). Per the ticket's constraints, nothing was
installed or changed, and no Prose copy was restored. The answer below comes from Microsoft's
"Editions and supported features of SQL Server 2025" page (updated 2026-11-18), not from running
queries. The restore plus the `FOR SYSTEM_TIME` and `VECTOR_DISTANCE` run is still unverified and
should be done once Docker (or the Developer edition) is available.

## Findings (Microsoft docs)

| Need | Express 2025 | Source row |
| --- | --- | --- |
| `VECTOR` data type | Yes | AI features: Native vector data type |
| `VECTOR_DISTANCE` | Yes (part of the native vector support; no edition gate listed) | AI features |
| DiskANN vector index | Yes, but needs the `PREVIEW_FEATURES` database scoped configuration | AI features, footnote 1 |
| System-versioned temporal tables (`FOR SYSTEM_TIME`) | Yes | Programmability: Temporal tables |
| Max relational database size | 50 GB per database (was 10 GB in older Express) | Scale limits |
| Compute | 1 socket / 4 cores | Scale limits |
| Buffer pool | 1,410 MB per instance | Scale limits |
| Columnstore cache / memory-optimized data | 352 MB | Scale limits |

Size fit: Prose 18.6 GB and IdiotProof_History 12.3 GB are both under 50 GB (37% and 25% of the
cap). Express caps each database separately, so both fit in one instance. Headroom for Prose is
about 31 GB.

## Where Express falls short (not a blocker for size or features)

- Buffer pool of about 1.4 GB against an 18.6 GB database: queries will page from disk. Brute-force
  `VECTOR_DISTANCE` scans over a large table will be I/O bound. A DiskANN index (preview) would help
  but is preview-only.
- 4 cores, and batch-mode DOP of 1 (Standard: 2). Parallel scans are limited.
- No backup compression, no SQL Server Agent (scheduled jobs need Task Scheduler), no TDE.
- Vector columns count toward the 50 GB cap. Growth of Prose by about 2.7x would hit it.
- Not stated by Microsoft in the page read: behavior at the cap (reported elsewhere as read-only
  or failed inserts; unconfirmed).

## Recommendation

1. Express 2025 is sufficient today on features and size. Use it if the workload is dev/low-concurrency
   and the 1.4 GB buffer pool is acceptable.
2. If Prose vector search or temporal history queries are too slow, or Prose approaches about 40 GB,
   move to Developer edition (free, full Enterprise features, 524 PB cap, OS-max memory). This is
   non-production use only. Developer is the right pick for this machine, which is a dev box.
3. Standard (256 GB buffer pool, 32 cores, paid) is only warranted for a production deployment.
   Splitting Prose across databases to dodge the cap is not recommended: it breaks cross-table
   vector and temporal queries for no gain over Developer.

## Follow-up to close the gap

Start Docker (or use Developer edition) and: restore a Prose copy, run `FOR SYSTEM_TIME` and
`VECTOR_DISTANCE` queries, and time them against the 1.4 GB buffer pool. Never touch the localhost
SQL Server memory cap while doing so.

Sources: https://learn.microsoft.com/en-us/sql/sql-server/editions-and-components-of-sql-server-2025
