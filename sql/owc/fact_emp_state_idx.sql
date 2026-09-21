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
WITH OK_COUNTY AS (
    SELECT
        YEAR,
        MONTH,
        AREAID_NAME,
        EMP
    FROM
        LIGHTCAST.TULSA_FOR_YOU.DAT_LABOR_FORCE
    WHERE
        AREAID_TYPE = 'STATE'
        AND AREAID_NAME = 'Oklahoma'
        AND YEAR >= 2015
)
SELECT
    DATE_FROM_PARTS(t1.YEAR, t1.MONTH, 1) AS DATE,
    t1.YEAR,
    t1.MONTH,
    t1.AREAID_NAME,
    t1.EMP,
    t2.EMP AS BASE_2015_EMP,
    t1.EMP / t2.EMP AS EMP_INDEX_TO_2015
FROM
    OK_COUNTY t1
INNER JOIN
    OK_COUNTY t2
ON
    t1.AREAID_NAME = t2.AREAID_NAME
    AND t2.YEAR = 2015
    AND t2.MONTH = 1