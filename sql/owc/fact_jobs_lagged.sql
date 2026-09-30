/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Lagged (prior-year) counterpart to fact_jobs, used for year-over-year
--                   comparisons.
--
-- Date:            2026-07-27
--
-- Notes:
-- Identical to fact_jobs, except YEAR_POSTED is shifted forward by 1 (YEAR(P.POSTED) + 1)
-- so each row lines up with the following year's fact_jobs row when joined on
-- YEAR_POSTED/AREAID/etc.
--
---------------------------------------------------------------------------------------------------
*/

SELECT
    YEAR(P.POSTED) + 1 AS YEAR_POSTED,
    QUARTER(P.POSTED) AS QUARTER_POSTED,  -- ADD quarterly; the past 3 months comparsions;
    MONTH(P.POSTED) AS MONTH_POSTED,      -- ADD monthly; the past 1 month comparsion
    P.COUNTY AS AREAID,
    --NAICS6 AS INDID,
    ICP.LC_BUCKET_INDID AS INDID,
    P.SOC_5 AS OCCID,
    P.COMPANY,
    P.MIN_EDULEVELS,
    P.IS_INTERNSHIP,
    COUNT(*) AS CURR_NUM_JOBS,
    SUM(P.DURATION) AS CURR_TOTAL_DURATION,
    COUNT(P.DURATION) AS CURR_N_WITH_DURATION,
    SUM(P.DUPLICATES + 1) AS CURR_TOTAL_TIMES_JOB_POSTED,
    SUM(P.SALARY) AS CURR_TOTAL_SALARY,
    COUNT(P.SALARY) AS CURR_N_WITH_SALARY
FROM
    LIGHTCAST.TULSA_FOR_YOU.POSTINGS AS P
LEFT JOIN
    TULSA_FOR_YOU.VIEWS.INDUSTRY_CROSSWALK_POSTINGS_TO_LC AS ICP
ON
    P.NAICS6 = ICP.POSTINGS_NAICS6
WHERE
    COMPANY_IS_STAFFING = FALSE
GROUP BY
    YEAR_POSTED,
    QUARTER_POSTED,
    MONTH_POSTED,
    AREAID,
    COMPANY,
    INDID,
    OCCID,
    MIN_EDULEVELS,
    IS_INTERNSHIP