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
-- Author:          Nile Dixon
-- Date:            2025-10-29
--
-- Notes:
-- 
--
--
---------------------------------------------------------------------------------------------------
*/

SELECT
    YEAR(POSTED) AS YEAR_POSTED,
    COUNTY AS AREAID,
    NAICS6 AS INDID,
    SOC_5 AS OCCID,
    COMPANY,
    MIN_EDULEVELS,
    IS_INTERNSHIP,
    COUNT(*) AS CURR_NUM_JOBS,
    SUM(DURATION) AS CURR_TOTAL_DURATION,
    COUNT(DURATION) AS CURR_N_WITH_DURATION,
    SUM(DUPLICATES + 1) AS CURR_TOTAL_TIMES_JOB_POSTED,
    SUM(SALARY) AS CURR_TOTAL_SALARY,
    COUNT(SALARY) AS CURR_N_WITH_SALARY
FROM LIGHTCAST.TULSA_FOR_YOU.POSTINGS
WHERE
    COMPANY_IS_STAFFING = FALSE
GROUP BY
    YEAR_POSTED,
    AREAID,
    COMPANY,
    INDID,
    OCCID,
    MIN_EDULEVELS,
    IS_INTERNSHIP
