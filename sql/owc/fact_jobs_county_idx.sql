/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds an annual job postings index by county, indexed to a 2015 baseline
--                   (2015 = 1.0).
--
-- Date:            2025-11-19
--
-- Notes:
-- Source: LIGHTCAST.TULSA_FOR_YOU.POSTINGS, from 2015 onward, excluding postings from
-- staffing companies (COMPANY_IS_STAFFING = False). Each county's yearly posting count is
-- self-joined to that county's 2015 count (BASE_2015_JOBS) to compute JOBS_INDEX_TO_2015.
--
---------------------------------------------------------------------------------------------------
*/

WITH OK_COUNTY AS (
    SELECT
        YEAR(POSTED) AS YEAR_POSTED,
        COUNTY_NAME AS AREAID,
        COUNT(*) AS CURR_NUM_JOBS
    FROM
        LIGHTCAST.TULSA_FOR_YOU.POSTINGS
    WHERE
        COMPANY_IS_STAFFING = False
        AND YEAR_POSTED >= 2015
    GROUP BY
        YEAR_POSTED,
        AREAID
)
SELECT
    DATE_FROM_PARTS(t1.YEAR_POSTED, 1, 1) AS DATE,
    t1.YEAR_POSTED,
    t1.AREAID,
    t1.CURR_NUM_JOBS,
    t2.CURR_NUM_JOBS AS BASE_2015_JOBS,
    t1.CURR_NUM_JOBS / t2.CURR_NUM_JOBS AS JOBS_INDEX_TO_2015
FROM
    OK_COUNTY t1
INNER JOIN
    OK_COUNTY t2
    ON t1.AREAID = t2.AREAID
    AND t2.YEAR_POSTED = 2015