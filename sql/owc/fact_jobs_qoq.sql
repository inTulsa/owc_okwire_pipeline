/*
---------------------------------------------------------------------------------------------------
--
-- Description: This is a SQL query that retrieves the following values for the current and previous year:
    - Number of jobs (*_NUM_JOBS)
    - Total number of days posting was open (*_TOTAL_DURATION)
    - Number of job postings where the DURATION field was not null (*_N_WITH_DURATION)
    - Total number of times a job was posted (*_TOTAL_TIMES_JOB_POSTED)
    - Sum of all salaries for job posting (*_TOTAL_SALARY)
    - Number of job postings where the SALARY field was not null (*_N_WITH_SALARY)
   Grouped by the following fields:
    - Year Posted, 
    - County,
    - AREAID,
    - INDID,
    - OCCID,
    - MIN_EDULEVELS,
    - IS_INTERNSHIP
--
-- Author:          Steven Vang
-- Date:            2026-07-27
--
-- Notes:
-- 
--
--
---------------------------------------------------------------------------------------------------
*/

-- SELECT
--     YEAR(POSTED) AS YEAR_POSTED,
--     QUARTER(POSTED) AS QUARTER_POSTED,  -- ADD quarterly; the past 3 months comparsions;
--     MONTH(POSTED) AS MONTH_POSTED,      -- ADD monthly; the past 1 month comparsion
--     COUNTY AS AREAID,
--     NAICS6 AS INDID,
--     SOC_5 AS OCCID,
--     COMPANY,
--     MIN_EDULEVELS,
--     IS_INTERNSHIP,
--     COUNT(*) AS CURR_NUM_JOBS,
--     SUM(DURATION) AS CURR_TOTAL_DURATION,
--     COUNT(DURATION) AS CURR_N_WITH_DURATION,
--     SUM(DUPLICATES + 1) AS CURR_TOTAL_TIMES_JOB_POSTED,
--     SUM(SALARY) AS CURR_TOTAL_SALARY,
--     COUNT(SALARY) AS CURR_N_WITH_SALARY
-- FROM LIGHTCAST.TULSA_FOR_YOU.POSTINGS
-- WHERE
--     COMPANY_IS_STAFFING = FALSE
-- GROUP BY
--     YEAR_POSTED,
--     QUARTER_POSTED,
--     MONTH_POSTED,
--     AREAID,
--     COMPANY,
--     INDID,
--     OCCID,
--     MIN_EDULEVELS,
--     IS_INTERNSHIP

-- SELECT
--     YEAR(P.POSTED) AS YEAR_POSTED,
--     QUARTER(P.POSTED) AS QUARTER_POSTED,  -- ADD quarterly; the past 3 months comparsions;
--     MONTH(P.POSTED) AS MONTH_POSTED,      -- ADD monthly; the past 1 month comparsion
--     P.COUNTY AS AREAID,
--     --NAICS6 AS INDID,                    -- STEVEN COMMENTED OUT
--     ICP.LC_BUCKET_INDID AS INDID,         -- STEVEN ADDED
--     P.SOC_5 AS OCCID,
--     P.COMPANY,
--     P.MIN_EDULEVELS,
--     P.IS_INTERNSHIP,
--     COUNT(*) AS CURR_NUM_JOBS,
--     SUM(P.DURATION) AS CURR_TOTAL_DURATION,
--     COUNT(P.DURATION) AS CURR_N_WITH_DURATION,
--     SUM(P.DUPLICATES + 1) AS CURR_TOTAL_TIMES_JOB_POSTED,
--     SUM(P.SALARY) AS CURR_TOTAL_SALARY,
--     COUNT(P.SALARY) AS CURR_N_WITH_SALARY
-- FROM
--     LIGHTCAST.TULSA_FOR_YOU.POSTINGS AS P
-- LEFT JOIN                                                                   
--     TULSA_FOR_YOU.VIEWS.INDUSTRY_CROSSWALK_POSTINGS_TO_LC AS ICP            -- STEVEN ADDED
-- ON
--     P.NAICS6 = ICP.POSTINGS_NAICS6                                          -- STEVEN ADDED
-- WHERE
--     COMPANY_IS_STAFFING = FALSE
-- GROUP BY
--     YEAR_POSTED,
--     QUARTER_POSTED,
--     MONTH_POSTED,
--     AREAID,
--     COMPANY,
--     INDID,
--     OCCID,
--     MIN_EDULEVELS,
--     IS_INTERNSHIP

SELECT
    YEAR(P.POSTED) AS YEAR_POSTED,
    QUARTER(P.POSTED) AS QUARTER_POSTED,  -- ADD quarterly; the past 3 months comparsions;
    MONTH(P.POSTED) AS MONTH_POSTED,      -- ADD monthly; the past 1 month comparsion
    P.COUNTY AS AREAID,
    --NAICS6 AS INDID,                    -- STEVEN COMMENTED OUT
    ICP.LC_BUCKET_INDID AS INDID,         -- STEVEN ADDED
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
    TULSA_FOR_YOU.VIEWS.INDUSTRY_CROSSWALK_POSTINGS_TO_LC AS ICP        -- STEVEN ADDED
ON
    P.NAICS6 = ICP.POSTINGS_NAICS6                                      -- STEVEN ADDED
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