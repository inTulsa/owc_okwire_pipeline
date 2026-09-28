/*
---------------------------------------------------------------------------------------------------
--
-- Description: This SQL query retrieves the lowest level and highest level NAICS code from the 
	DIM_INDID table in lightcast.
--
-- Author:          Steven Vang
-- Date:            2026-09-21
--
-- Notes: Main data source used for OWC dashboards in the dim_ind table; sourced back to
        lightcast "DIM_IND - Normalized" worksheet.
-- 
--
--
---------------------------------------------------------------------------------------------------
*/

WITH combined_naics AS (
  SELECT
    name,
    level,
    indid,
    indid_parent,
    'dim_indid' AS source
  FROM dim_indid

  UNION ALL
  SELECT DISTINCT naics6_name, 6, naics6, naics5, 'postings'
  FROM postings
  WHERE naics6 IS NOT NULL

  UNION ALL
  SELECT DISTINCT naics5_name, 5, naics5, naics4, 'postings'
  FROM postings
  WHERE naics5 IS NOT NULL

  UNION ALL
  SELECT DISTINCT naics4_name, 4, naics4, naics3, 'postings'
  FROM postings
  WHERE naics4 IS NOT NULL

  UNION ALL
  SELECT DISTINCT naics3_name, 3, naics3, naics2, 'postings'
  FROM postings
  WHERE naics3 IS NOT NULL

  UNION ALL
  SELECT DISTINCT naics2_name, 2, naics2, NULL, 'postings'
  FROM postings
  WHERE naics2 IS NOT NULL
),

/* ✅ FIX: one row per INDID (prevents dirty parent chains + dupes) */
prioritized_naics AS (
  SELECT indid, name, level, indid_parent
  FROM (
    SELECT
      indid,
      name,
      level,
      indid_parent,
      ROW_NUMBER() OVER (
        PARTITION BY indid
        ORDER BY CASE WHEN source = 'dim_indid' THEN 1 ELSE 2 END
      ) AS rn
    FROM combined_naics
  )
  WHERE rn = 1
),

/* -----------------------------
   A) Original level-6 output (unchanged behavior)
   ----------------------------- */
level6_dim AS (
  SELECT DISTINCT
    TRIM(c2.indid) AS TLINDID,
    TRIM(c2.name) AS NAICS2_NAME,
    TRIM(c6.indid) AS INDID,
    TRIM(c6.name) AS NAICS6_NAME,
    TRIM(c5.indid) AS naics5_code,
    TRIM(c5.name) AS naics5_name,
    TRIM(c4.indid) AS naics4_code,
    TRIM(c4.name) AS naics4_name,
    TRIM(c3.indid) AS naics3_code,
    TRIM(c3.name) AS naics3_name
  FROM prioritized_naics AS c6
  LEFT JOIN prioritized_naics AS c5 ON c6.indid_parent = c5.indid
  LEFT JOIN prioritized_naics AS c4 ON c5.indid_parent = c4.indid
  LEFT JOIN prioritized_naics AS c3 ON c4.indid_parent = c3.indid
  LEFT JOIN prioritized_naics AS c2 ON c3.indid_parent = c2.indid
  WHERE c6.level = 6
),

/* -----------------------------
   B) Bucket keys from your crosswalk (non-6-digit IndustryKeys)
   NOTE: This is the critical part.
   ----------------------------- */
bucket_keys AS (
  SELECT DISTINCT TRIM(LC_BUCKET_INDID) AS INDID
  FROM TULSA_FOR_YOU.VIEWS.INDUSTRY_CROSSWALK_POSTINGS_TO_LC
  WHERE LC_BUCKET_INDID IS NOT NULL
    AND LENGTH(TRIM(LC_BUCKET_INDID)) <> 6
),

/* -----------------------------
   C) Append bucket rows directly (no dependency on DIM_INDID having them)
   ----------------------------- */
bucket_dim AS (
  SELECT DISTINCT
    /* TLINDID */
    CASE
      WHEN LENGTH(b.INDID) = 2 THEN b.INDID
      ELSE LEFT(b.INDID, 2)
    END AS TLINDID,

    /* NAICS2_NAME (try to look it up if it exists; otherwise hardcode Government) */
    COALESCE(
      p2.name,
      CASE WHEN LEFT(b.INDID, 2) = '90' THEN 'Government' END
    ) AS NAICS2_NAME,

    b.INDID AS INDID,

    /* NAICS6_NAME for the bucket row (fallback to a label if unknown) */
    COALESCE(
      bn.name,
      CASE WHEN b.INDID = '90' THEN 'Government' END,
      CONCAT('Bucket ', b.INDID)
    ) AS NAICS6_NAME,

    /* Leave middle levels blank for bucket rows */
    CAST(NULL AS VARCHAR) AS naics5_code,
    CAST(NULL AS VARCHAR) AS naics5_name,
    CAST(NULL AS VARCHAR) AS naics4_code,
    CAST(NULL AS VARCHAR) AS naics4_name,
    CAST(NULL AS VARCHAR) AS naics3_code,
    CAST(NULL AS VARCHAR) AS naics3_name

  FROM bucket_keys b

  /* lookup NAICS2 sector name if it exists */
  LEFT JOIN prioritized_naics p2
    ON p2.indid = CASE
                    WHEN LENGTH(b.INDID) = 2 THEN b.INDID
                    ELSE LEFT(b.INDID, 2)
                  END
   AND p2.level = 2

  /* try to find a name for the bucket itself if it happens to exist in combined_naics */
  LEFT JOIN (
    SELECT TRIM(indid) AS indid, MAX(TRIM(name)) AS name
    FROM combined_naics
    GROUP BY 1
  ) bn
    ON bn.indid = b.indid
)

SELECT * FROM level6_dim
UNION ALL
SELECT * FROM bucket_dim
ORDER BY INDID asc
