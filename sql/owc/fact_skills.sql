/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the skills fact table: counts of job postings mentioning each skill,
--                   alongside the total job count for the same grouping, by year, quarter,
--                   month, area, industry, occupation, minimum education, and internship flag.
--
-- Date:            2026-07-31
--
-- Notes:
-- QUARTER_POSTED/MONTH_POSTED support quarter-over-quarter and month-over-month comparisons
-- for the OWC dashboards. INDID is sourced from the industry crosswalk CTE (INDID_CROSSWALK),
-- which maps each posting's NAICS6 to a Lightcast bucket code, rather than using raw NAICS6
-- directly. TJ provides CURR_TOTAL_JOBS_COUNT, the total postings for the same grouping,
-- so skill counts can be read as a share of total jobs.
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
        YEAR(POSTED) AS YEAR_POSTED,
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
    YEAR(P.POSTED) AS YEAR_POSTED,
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
    ON YEAR(P.POSTED) = T.YEAR_POSTED
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