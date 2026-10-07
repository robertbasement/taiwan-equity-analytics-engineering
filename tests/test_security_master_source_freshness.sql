SELECT *
FROM {{ ref('dim_security_master') }}
WHERE source_as_of_date < DATE_SUB(CURRENT_DATE('Asia/Taipei'), INTERVAL 7 DAY)
   OR source_as_of_date > CURRENT_DATE('Asia/Taipei')
