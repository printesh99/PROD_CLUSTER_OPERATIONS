# Index Recommendations From Metadata

Created: 2026-05-25

This analysis was run against the local metadata-only PostgreSQL lab imported from `pg_report_3.html`. It checks every imported database for foreign-key constraints where the child table does not have a matching leading-column index.

This is a metadata-driven recommendation, not a command to blindly change production. Validate each candidate against live workload, table size, DML frequency, and existing execution plans before creating indexes.

## Summary

| Item | Count |
|---|---:|
| Databases analyzed | 25 |
| Databases with missing-index candidates | 16 |
| Foreign keys missing child-side leading index | 538 |

## Count By Database

| Database | Missing FK Index Candidates |
|---|---:|
| `ae_service_uat` | 86 |
| `ch_service_uat` | 83 |
| `sa_service_uat` | 83 |
| `uk_service_uat` | 83 |
| `ae_tps_uat` | 39 |
| `ch_tps_uat` | 39 |
| `sa_tps_uat` | 39 |
| `uk_tps_uat` | 39 |
| `ae_common_uat` | 9 |
| `ch_common_uat` | 9 |
| `sa_common_uat` | 9 |
| `uk_common_uat` | 9 |
| `druatrhbk` | 5 |
| `ae_api_gateway_uat` | 2 |
| `sa_api_gateway_uat` | 2 |
| `uk_api_gateway_uat` | 2 |

## Highest Priority Candidates

Priority is based on the child table size from the source HTML report. Larger child tables generally carry higher risk for slow joins, slow deletes/updates on parent tables, and expensive referential-integrity checks.

| Database | Table | FK columns | Constraint | Report table size | Live | Dead | Dead % |
|---|---|---|---|---:|---:|---:|---:|
| `ae_tps_uat` | `tps.transaction_ledger` | `transaction_id, sequence_number` | `transaction_ledger_transaction_audit_sequence_fk` | 109 GB | 20 | 0 | 0.00% |
| `ae_tps_uat` | `tps.unposted_transaction` | `account_number` | `unposted_transaction_account_fk` | 95 GB | 104 | 0 | 0.00% |
| `ae_tps_uat` | `tps.transaction_audit` | `login_name` | `transaction_audit_system_user_fk` | 47 GB | 741 | 0 | 0.00% |
| `sa_tps_uat` | `tps.transaction_ledger` | `transaction_id, sequence_number` | `transaction_ledger_transaction_audit_sequence_fk` | 17 GB | 0 | 0 | 0% |
| `sa_tps_uat` | `tps.unposted_transaction` | `account_number` | `unposted_transaction_account_fk` | 14 GB | 0 | 0 | 0% |
| `ae_tps_uat` | `tps.transaction_reference` | `branch_id` | `transaction_reference_organization_fk` | 12 GB | 214 | 0 | 0.00% |
| `uk_tps_uat` | `tps.transaction_ledger` | `transaction_id, sequence_number` | `transaction_ledger_transaction_audit_sequence_fk` | 10 GB | 30 | 0 | 0.00% |
| `uk_tps_uat` | `tps.unposted_transaction` | `account_number` | `unposted_transaction_account_fk` | 8092 MB | 46 | 0 | 0.00% |
| `sa_tps_uat` | `tps.transaction_audit` | `login_name` | `transaction_audit_system_user_fk` | 5284 MB | 6 | 3 | 33.33% |
| `ae_tps_uat` | `tps.account_serial_balance` | `currency_id` | `account_serial_balance_currency_fk` | 3791 MB | 4 | 0 | 0.00% |
| `ch_tps_uat` | `tps.transaction_ledger` | `transaction_id, sequence_number` | `transaction_ledger_transaction_audit_sequence_fk` | 3650 MB | 0 | 0 | 0% |
| `uk_tps_uat` | `tps.transaction_audit` | `login_name` | `transaction_audit_system_user_fk` | 3558 MB | 61 | 0 | 0.00% |
| `ch_tps_uat` | `tps.unposted_transaction` | `account_number` | `unposted_transaction_account_fk` | 2743 MB | 0 | 0 | 0% |
| `sa_tps_uat` | `tps.transaction_reference` | `branch_id` | `transaction_reference_organization_fk` | 1210 MB | 2 | 3 | 60.00% |
| `ch_tps_uat` | `tps.transaction_audit` | `login_name` | `transaction_audit_system_user_fk` | 989 MB | 6 | 0 | 0.00% |
| `uk_tps_uat` | `tps.transaction_reference` | `branch_id` | `transaction_reference_organization_fk` | 862 MB | 17 | 0 | 0.00% |
| `uk_tps_uat` | `tps.account_serial_balance` | `currency_id` | `account_serial_balance_currency_fk` | 321 MB | 8 | 0 | 0.00% |
| `sa_tps_uat` | `tps.account_serial_balance` | `currency_id` | `account_serial_balance_currency_fk` | 274 MB | 0 | 0 | 0% |
| `ae_service_uat` | `crm.account` | `product_id` | `account_product_fk` | 252 MB | 39 | 101 | 72.14% |
| `ae_service_uat` | `crm.account` | `currency_id` | `account_currency_fk` | 252 MB | 39 | 101 | 72.14% |
| `ae_service_uat` | `crm.account` | `branch_unit_id` | `account_branch_unit_fk` | 252 MB | 39 | 101 | 72.14% |
| `ch_tps_uat` | `tps.transaction_reference` | `branch_id` | `transaction_reference_organization_fk` | 221 MB | 2 | 0 | 0.00% |
| `ae_service_uat` | `crm.customer` | `residency` | `customer_country_fk` | 142 MB | 20 | 135 | 87.10% |
| `ae_tps_uat` | `crm.account` | `product_id` | `account_product_fk` | 127 MB | 39 | 93 | 70.45% |
| `ae_tps_uat` | `crm.account` | `branch_unit_id` | `account_organization_sub_unit_fk` | 127 MB | 39 | 93 | 70.45% |
| `ae_tps_uat` | `crm.account` | `currency_id` | `account_currency_fk` | 127 MB | 39 | 93 | 70.45% |
| `ch_tps_uat` | `tps.account_serial_balance` | `currency_id` | `account_serial_balance_currency_fk` | 118 MB | 0 | 0 | 0% |
| `ae_service_uat` | `crm.gsm_service` | `person_id` | `gsm_service_person_fk` | 104 MB | 47 | 132 | 73.74% |
| `ae_service_uat` | `crm.gsm_service` | `account_number` | `gsm_service_account_fk` | 104 MB | 47 | 132 | 73.74% |
| `ae_service_uat` | `crm.customer_signatory` | `person_id` | `customer_signatory_person_id_fkey` | 80 MB | 39 | 567 | 93.56% |
| `sa_tps_uat` | `crm.account` | `product_id` | `account_product_fk` | 55 MB | 0 | 0 | 0% |
| `sa_tps_uat` | `crm.account` | `branch_unit_id` | `account_organization_sub_unit_fk` | 55 MB | 0 | 0 | 0% |
| `sa_tps_uat` | `crm.account` | `currency_id` | `account_currency_fk` | 55 MB | 0 | 0 | 0% |
| `ae_tps_uat` | `crm.customer` | `residency` | `customer_residency_fk` | 52 MB | 20 | 2 | 9.09% |
| `ae_tps_uat` | `crm.customer` | `branch_id` | `customer_branch_fk` | 52 MB | 20 | 2 | 9.09% |
| `ae_service_uat` | `crm.person_customer` | `customer_id` | `person_customer_customer_id_fkey` | 47 MB | 28 | 347 | 92.53% |
| `ch_tps_uat` | `crm.account` | `product_id` | `account_product_fk` | 44 MB | 0 | 0 | 0% |
| `ch_tps_uat` | `crm.account` | `branch_unit_id` | `account_organization_sub_unit_fk` | 44 MB | 0 | 0 | 0% |
| `ch_tps_uat` | `crm.account` | `currency_id` | `account_currency_fk` | 44 MB | 0 | 0 | 0% |
| `uk_tps_uat` | `crm.account` | `product_id` | `account_product_fk` | 37 MB | 2 | 43 | 95.56% |

## Suggested Index DDL Templates

Use these as templates only. On production, prefer `CREATE INDEX CONCURRENTLY` outside a transaction, one index at a time, during a controlled window. Confirm that an equivalent index does not already exist with different column order or partial predicate.

```sql
-- ae_tps_uat | 109 GB | FK transaction_ledger_transaction_audit_sequence_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_transaction_ledger_transaction_id_sequence_number_fk"
ON "tps"."transaction_ledger" ("transaction_id", "sequence_number");

-- ae_tps_uat | 95 GB | FK unposted_transaction_account_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_unposted_transaction_account_number_fk"
ON "tps"."unposted_transaction" ("account_number");

-- ae_tps_uat | 47 GB | FK transaction_audit_system_user_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_transaction_audit_login_name_fk"
ON "tps"."transaction_audit" ("login_name");

-- sa_tps_uat | 17 GB | FK transaction_ledger_transaction_audit_sequence_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_transaction_ledger_transaction_id_sequence_number_fk"
ON "tps"."transaction_ledger" ("transaction_id", "sequence_number");

-- sa_tps_uat | 14 GB | FK unposted_transaction_account_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_unposted_transaction_account_number_fk"
ON "tps"."unposted_transaction" ("account_number");

-- ae_tps_uat | 12 GB | FK transaction_reference_organization_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_transaction_reference_branch_id_fk"
ON "tps"."transaction_reference" ("branch_id");

-- uk_tps_uat | 10 GB | FK transaction_ledger_transaction_audit_sequence_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_transaction_ledger_transaction_id_sequence_number_fk"
ON "tps"."transaction_ledger" ("transaction_id", "sequence_number");

-- uk_tps_uat | 8092 MB | FK unposted_transaction_account_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_unposted_transaction_account_number_fk"
ON "tps"."unposted_transaction" ("account_number");

-- sa_tps_uat | 5284 MB | FK transaction_audit_system_user_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_transaction_audit_login_name_fk"
ON "tps"."transaction_audit" ("login_name");

-- ae_tps_uat | 3791 MB | FK account_serial_balance_currency_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_account_serial_balance_currency_id_fk"
ON "tps"."account_serial_balance" ("currency_id");

-- ch_tps_uat | 3650 MB | FK transaction_ledger_transaction_audit_sequence_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_transaction_ledger_transaction_id_sequence_number_fk"
ON "tps"."transaction_ledger" ("transaction_id", "sequence_number");

-- uk_tps_uat | 3558 MB | FK transaction_audit_system_user_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_transaction_audit_login_name_fk"
ON "tps"."transaction_audit" ("login_name");

-- ch_tps_uat | 2743 MB | FK unposted_transaction_account_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_unposted_transaction_account_number_fk"
ON "tps"."unposted_transaction" ("account_number");

-- sa_tps_uat | 1210 MB | FK transaction_reference_organization_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_transaction_reference_branch_id_fk"
ON "tps"."transaction_reference" ("branch_id");

-- ch_tps_uat | 989 MB | FK transaction_audit_system_user_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_transaction_audit_login_name_fk"
ON "tps"."transaction_audit" ("login_name");

-- uk_tps_uat | 862 MB | FK transaction_reference_organization_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_transaction_reference_branch_id_fk"
ON "tps"."transaction_reference" ("branch_id");

-- uk_tps_uat | 321 MB | FK account_serial_balance_currency_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_account_serial_balance_currency_id_fk"
ON "tps"."account_serial_balance" ("currency_id");

-- sa_tps_uat | 274 MB | FK account_serial_balance_currency_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_account_serial_balance_currency_id_fk"
ON "tps"."account_serial_balance" ("currency_id");

-- ae_service_uat | 252 MB | FK account_product_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_account_product_id_fk"
ON "crm"."account" ("product_id");

-- ae_service_uat | 252 MB | FK account_currency_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_account_currency_id_fk"
ON "crm"."account" ("currency_id");

-- ae_service_uat | 252 MB | FK account_branch_unit_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_account_branch_unit_id_fk"
ON "crm"."account" ("branch_unit_id");

-- ch_tps_uat | 221 MB | FK transaction_reference_organization_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_transaction_reference_branch_id_fk"
ON "tps"."transaction_reference" ("branch_id");

-- ae_service_uat | 142 MB | FK customer_country_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_customer_residency_fk"
ON "crm"."customer" ("residency");

-- ae_tps_uat | 127 MB | FK account_product_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_account_product_id_fk"
ON "crm"."account" ("product_id");

-- ae_tps_uat | 127 MB | FK account_organization_sub_unit_fk
CREATE INDEX CONCURRENTLY IF NOT EXISTS "idx_account_branch_unit_id_fk"
ON "crm"."account" ("branch_unit_id");

```

## Production Validation Queries

Find FK columns without a matching child-side leading index in the current database:

```sql
with fk as (
  select con.oid, con.conname, n.nspname as schema_name, c.relname as table_name,
         con.conrelid, con.conkey,
         array_agg(a.attname order by ord.n) as fk_columns
  from pg_constraint con
  join pg_class c on c.oid = con.conrelid
  join pg_namespace n on n.oid = c.relnamespace
  join unnest(con.conkey) with ordinality as ord(attnum,n) on true
  join pg_attribute a on a.attrelid = con.conrelid and a.attnum = ord.attnum
  where con.contype = 'f'
    and n.nspname not in ('pg_catalog', 'information_schema', 'pg_toast')
  group by con.oid, con.conname, n.nspname, c.relname, con.conrelid, con.conkey
), idx as (
  select i.indrelid, i.indexrelid::regclass::text as index_name, i.indkey::int2[] as indkey
  from pg_index i
  where i.indisvalid and i.indisready
)
select fk.schema_name, fk.table_name, fk.conname,
       array_to_string(fk.fk_columns, ', ') as fk_columns
from fk
where not exists (
  select 1
  from idx
  where idx.indrelid = fk.conrelid
    and idx.indkey[0:array_length(fk.conkey,1)-1] = fk.conkey
)
order by fk.schema_name, fk.table_name, fk.conname;
```

Check whether a candidate table is actually large/hot in production:

```sql
select
  schemaname,
  relname,
  pg_size_pretty(pg_total_relation_size(relid)) as total_size,
  seq_scan,
  idx_scan,
  n_live_tup,
  n_dead_tup,
  last_autovacuum,
  last_autoanalyze
from pg_stat_user_tables
where schemaname = '<schema_name>'
  and relname = '<table_name>';
```

## Notes

- A missing child-side FK index is not always wrong. Small lookup tables or rarely modified parent rows may not need an extra index.
- Composite foreign keys need an index with the same leading column order as the FK columns.
- Existing broader indexes may be sufficient if they start with the FK columns.
- Avoid creating many indexes at once. Each index adds storage and write overhead.
- The local lab has no production data, so size/ranking comes from the original report, not the local empty tables.
