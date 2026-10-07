{{ config(materialized='table', cluster_by=['ticker', 'market']) }}

SELECT *
FROM {{ ref('stg_security_master') }}
