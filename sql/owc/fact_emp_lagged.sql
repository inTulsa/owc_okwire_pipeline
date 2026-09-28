WITH
params AS (
    SELECT YEAR(CURRENT_DATE())  AS max_year
),

/* 1) Truth totals by occupation (Option B: OCC includes CLASSID 1+2+3, excludes 4) */
occ_totals AS (
    SELECT
        o.YEAR + 1 AS YEAR,
        o.AREAID,
        o.OCCID,
        SUM(o.EMP) AS occ_total_emp
    FROM LIGHTCAST.TULSA_FOR_YOU.DAT_OCC o
    JOIN LIGHTCAST.TULSA_FOR_YOU.DIM_OCCID docc
      ON o.OCCID = docc.OCCID
    CROSS JOIN params p
    WHERE o.AREAID_TYPE = 'COUNTY'
      AND o.CLASSID <> '4'
      AND o.YEAR <= p.max_year
      AND docc.LEVEL = 5  -- detailed SOC only; avoids aggregates like 00-0000
    GROUP BY 1,2,3
),

/* 2) Staffing patterns (distribution source: CLASSID=1 only) */
staffing_by_occ_ind AS (
    SELECT
        s.YEAR + 1 AS YEAR,
        s.AREAID,
        s.OCCID,
        s.INDID,
        SUM(s.EMP) AS staff_emp
    FROM LIGHTCAST.TULSA_FOR_YOU.DAT_STAFFING s
    JOIN LIGHTCAST.TULSA_FOR_YOU.DIM_OCCID docc
      ON s.OCCID = docc.OCCID
    JOIN LIGHTCAST.TULSA_FOR_YOU.DIM_INDID dind
      ON s.INDID = dind.INDID
    CROSS JOIN params p
    WHERE s.AREAID_TYPE = 'COUNTY'
      AND s.CLASSID = '1'
      AND s.YEAR <= p.max_year
      AND docc.LEVEL = 5  -- aligns to detailed SOC
      AND dind.LEVEL = 6  -- ensures NAICS level 6 only
    GROUP BY 1,2,3,4
),

/* 3) Normalize staffing to a per-occupation industry share (sums to 1 over INDID per OCCID) */
staffing_weights AS (
    SELECT
        YEAR,
        AREAID,
        OCCID,
        INDID,
        staff_emp,
        staff_emp / NULLIF(SUM(staff_emp) OVER (PARTITION BY YEAR, AREAID, OCCID), 0) AS pct_occ_to_ind
    FROM staffing_by_occ_ind
),

/* 4) Industry totals (Option B: IND includes CLASSID 1+2+3, excludes 4) */
ind_totals AS (
    SELECT
        i.YEAR + 1 AS YEAR,
        i.AREAID,
        i.INDID,
        SUM(i.EMP) AS num_emps
    FROM LIGHTCAST.TULSA_FOR_YOU.DAT_IND i
    JOIN LIGHTCAST.TULSA_FOR_YOU.DIM_INDID dind
      ON i.INDID = dind.INDID
    CROSS JOIN params p
    WHERE i.AREAID_TYPE = 'COUNTY'
      AND i.CLASSID <> '4'
      AND i.YEAR <= p.max_year
      AND dind.LEVEL = 6
    GROUP BY 1,2,3
),

/* 5) Mapped occupations: allocate DAT_OCC totals across industries using normalized staffing weights */
mapped AS (
    SELECT
        w.YEAR AS YEAR,
        w.AREAID,
        w.INDID,
        w.OCCID,
        it.num_emps AS NUM_EMPS,
        (o.occ_total_emp * w.pct_occ_to_ind) AS OCC_EMPS,
        w.pct_occ_to_ind AS PERCENT
    FROM staffing_weights w
    JOIN occ_totals o
      ON o.YEAR = w.YEAR
     AND o.AREAID = w.AREAID
     AND o.OCCID = w.OCCID
    LEFT JOIN ind_totals it
      ON it.YEAR = w.YEAR
     AND it.AREAID = w.AREAID
     AND it.INDID = w.INDID
),

/* 6) Unmapped occupations: keep totals visible (so you don't silently lose 50 OCCIDs) */
unmapped AS (
    SELECT
        o.YEAR AS YEAR,
        o.AREAID,
        NULL AS INDID,
        o.OCCID,
        CAST(NULL AS FLOAT) AS NUM_EMPS,
        o.occ_total_emp AS OCC_EMPS,
        1.0 AS PERCENT
    FROM occ_totals o
    LEFT JOIN (
        SELECT DISTINCT YEAR, AREAID, OCCID
        FROM staffing_weights
    ) w
      ON w.YEAR = o.YEAR
     AND w.AREAID = o.AREAID
     AND w.OCCID = o.OCCID
    WHERE w.OCCID IS NULL
),
final_cte AS (
    SELECT YEAR, AREAID, INDID, OCCID, NUM_EMPS, OCC_EMPS, PERCENT FROM mapped
    UNION ALL
    SELECT YEAR, AREAID, INDID, OCCID, NUM_EMPS, OCC_EMPS, PERCENT FROM unmapped     
)
SELECT *
FROM final_cte
ORDER BY YEAR, OCCID