/*
---------------------------------------------------------------------------------------------------
--
-- Description: 
--
-- Author:          Nile Dixon
-- Date:            2025-11-19
--
-- Notes:
-- 
--
--
---------------------------------------------------------------------------------------------------
*/

WITH OK_STATE AS (
    SELECT
        YEAR(POSTED) AS YEAR_POSTED,
        'Oklahoma' AS AREAID,
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
    OK_STATE t1
INNER JOIN
    OK_STATE t2
    ON t1.AREAID = t2.AREAID
    AND t2.YEAR_POSTED = 2015