/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Lagged (prior-year) counterpart to fact_skills, used for year-over-year
--                   comparisons.
--
-- Date:            2026-07-31
--
-- Notes:
-- Identical to fact_skills, except YEAR_POSTED is shifted forward by 1 (YEAR(POSTED) + 1)
-- in both the TJ CTE and the main query, so each row lines up with the following year's
-- fact_skills row when joined on YEAR_POSTED/AREAID/etc.
--
---------------------------------------------------------------------------------------------------
*/
WITH INDID_CROSSWALK AS (
    SELECT
        POSTINGS_NAICS6,
        LC_BUCKET_INDID
    FROM
        TULSA_FOR_YOU.VIEWS.INDUSTRY_CROSSWALK_POSTINGS_TO_LC 
),

TJ AS (
    SELECT
        YEAR(POSTED) + 1 AS YEAR_POSTED,
        QUARTER(POSTED) AS QUARTER_POSTED,      -- added quarterly postings
        MONTH(POSTED) AS MONTH_POSTED,          -- added monthly postings
        COUNTY AS AREAID,
        NAICS6 AS INDID,
        SOC_5 AS OCCID,
        MIN_EDULEVELS,
        IS_INTERNSHIP,
        COUNT(ID) AS TOTAL_JOBS_COUNT
    FROM
        LIGHTCAST.TULSA_FOR_YOU.POSTINGS AS P_TOTAL
    GROUP BY
        YEAR_POSTED,
        QUARTER_POSTED,                         -- added quarterly postings
        MONTH_POSTED,                           -- added monthly postings
        AREAID,
        INDID,
        OCCID,
        MIN_EDULEVELS,
        IS_INTERNSHIP
)
SELECT
    PS.SKILL_ID,
    YEAR(P.POSTED) + 1 AS YEAR_POSTED,
    QUARTER(P.POSTED) AS QUARTER_POSTED,       -- added quarterly postings
    MONTH(P.POSTED) AS MONTH_POSTED,           -- added monthly postings
    P.COUNTY AS AREAID,
    IC.LC_BUCKET_INDID AS INDID,
    P.SOC_5 AS OCCID,
    P.MIN_EDULEVELS,
    P.IS_INTERNSHIP,
    COUNT(*) AS CURR_NUM_SKILLS,
    T.TOTAL_JOBS_COUNT AS CURR_TOTAL_JOBS_COUNT
FROM
    LIGHTCAST.TULSA_FOR_YOU.POSTINGS_SKILLS AS PS
JOIN
    LIGHTCAST.TULSA_FOR_YOU.POSTINGS AS P
    ON PS.ID = P.ID
JOIN
    INDID_CROSSWALK AS IC
    ON P.NAICS6 = IC.POSTINGS_NAICS6
JOIN
    TJ AS T
    ON YEAR(P.POSTED) + 1 = T.YEAR_POSTED
    AND QUARTER(P.POSTED) = T.QUARTER_POSTED    -- added quarterly postings
    AND MONTH(P.POSTED) = T.MONTH_POSTED        -- added monthly postings
    AND P.COUNTY = T.AREAID
    AND P.NAICS6 = T.INDID
    AND P.SOC_5 = T.OCCID
    AND P.MIN_EDULEVELS = T.MIN_EDULEVELS
    AND P.IS_INTERNSHIP = T.IS_INTERNSHIP
WHERE
    P.COMPANY_IS_STAFFING = FALSE
GROUP BY
    PS.SKILL_ID,
    YEAR(P.POSTED),
    QUARTER(POSTED),                            -- added quarterly postings
    MONTH(POSTED),                              -- added monthly postings
    P.COUNTY,
    IC.LC_BUCKET_INDID,
    P.SOC_5,
    P.MIN_EDULEVELS,
    P.IS_INTERNSHIP,
    T.TOTAL_JOBS_COUNT