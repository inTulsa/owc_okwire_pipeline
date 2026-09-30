/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the industry wages fact table: average yearly earnings per employee
--                   by year, county, and industry.
--
-- Date:            2025-12-02
--
-- Notes:
-- Source: LIGHTCAST.TULSA_FOR_YOU.DAT_IND, filtered to CLASSID = 1 and AREAID_TYPE = 'COUNTY'.
-- Lightcast does not report a single per-employee wage value; instead it reports total
-- earnings (EARN) and headcount (EMP) separately, so average yearly wages must be derived
-- as EARN / EMP.
--
---------------------------------------------------------------------------------------------------
*/
SELECT 
    YEAR,
    AREAID,
    INDID,
    ROUND(EARN / EMP,2) AS YEARLY_WAGES
FROM 
    LIGHTCAST.TULSA_FOR_YOU.DAT_IND 
WHERE
    CLASSID = 1
    AND AREAID_TYPE = 'COUNTY'
    AND YEAR <= YEAR(CURRENT_DATE())