"""Security monitoring: fails (and so notifies) when any check returns rows.

Runs as a Jobs Serverless Python file task under the workspace service principal.
Arguments: <workspace_id> <workspace_catalog> <lookback_hours>
"""

import sys

from pyspark.sql import SparkSession

CHECKS = {
    # Uany growth or write on Databricks-owned default storage.
    "default_storage_usage": """
        SELECT usage_date, usage_type, SUM(usage_quantity) AS quantity
        FROM system.billing.usage
        WHERE billing_origin_product = 'DEFAULT_STORAGE'
          AND workspace_id = :workspace_id
          AND usage_date >= date_sub(current_date(), CAST(CEIL(:lookback_hours / 24) AS INT))
        GROUP BY ALL
    """,
    # Ucredential, location and network-policy changes (account events have workspace_id 0).
    "governance_changes": """
        SELECT event_time, service_name, action_name, user_identity.email AS actor
        FROM system.access.audit
        WHERE workspace_id IN (:workspace_id, 0)
          AND event_time >= current_timestamp() - make_interval(0, 0, 0, 0, :lookback_hours)
          AND action_name RLIKE '(?i)^(create|update|delete).*(StorageCredential|ExternalLocation|NetworkPolic|NetworkConnectivity)'
    """,
    # Uanything created in the revoked workspace catalog.
    "workspace_catalog_writes": """
        SELECT event_time, action_name, user_identity.email AS actor
        FROM system.access.audit
        WHERE workspace_id = :workspace_id
          AND event_time >= current_timestamp() - make_interval(0, 0, 0, 0, :lookback_hours)
          AND action_name RLIKE '^(create|update)(Table|Schema|Volume|Function)'
          AND to_json(request_params) LIKE CONCAT('%', :workspace_catalog, '%')
    """,
    # Userverless egress denials.
    "egress_denials": """
        SELECT event_time, destination_type, destination, access_type
        FROM system.access.outbound_network
        WHERE workspace_id = :workspace_id
          AND event_time >= current_timestamp() - make_interval(0, 0, 0, 0, :lookback_hours)
    """,
}


def main(workspace_id: str, workspace_catalog: str, lookback_hours: str) -> None:
    spark = SparkSession.builder.getOrCreate()
    args = {
        "workspace_id": int(workspace_id),
        "workspace_catalog": workspace_catalog,
        "lookback_hours": int(lookback_hours),
    }
    findings = {}
    for name, query in CHECKS.items():
        params = {k: v for k, v in args.items() if f":{k}" in query}
        rows = spark.sql(query, args=params).limit(50).collect()
        if rows:
            findings[name] = rows

    for name, rows in findings.items():
        print(f"== {name}: {len(rows)} row(s)")
        for row in rows:
            print(row.asDict())

    if findings:
        raise RuntimeError(f"Security checks returned rows: {', '.join(findings)}")
    print("All security checks clean.")


if __name__ == "__main__":
    main(*sys.argv[1:4])
