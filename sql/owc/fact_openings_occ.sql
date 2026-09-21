/*
---------------------------------------------------------------------------------------------------
--
-- Description: This SQL query retrieves the total number of opneings for a year by occupation. 
--
-- Author:          Nile Dixon
-- Date:            2025-12-02
--
-- Notes:
-- 
--
--
---------------------------------------------------------------------------------------------------
*/
SELECT
    YEAR,
    AREAID,
    OCCID,
    SUM(REPLACEMENTS) AS NUM_OPENINGS
FROM
    LIGHTCAST.TULSA_FOR_YOU.DAT_OCC
WHERE
    CLASSID <> 4
    AND AREAID_TYPE = 'COUNTY'
    AND YEAR <= YEAR(CURRENT_DATE()) 
GROUP BY
    YEAR,
    AREAID,
    OCCID