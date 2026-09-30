/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the occupation wages fact table: average hourly and yearly wages
--                   by year, county, and occupation.
--
-- Date:            2025-12-02
--
-- Notes:
-- Source: LIGHTCAST.TULSA_FOR_YOU.DAT_OCC, filtered to CLASSID = 1 (QCEW employees only) and
-- AREAID_TYPE = 'COUNTY'. YEARLY_WAGE is derived as HOURLY_WAGE * 2080 (standard full-time
-- hours/year). To include other employee classes, EARN_AVG would need to be combined via a
-- weighted average across EMP by CLASSID rather than filtered to CLASSID = 1 alone.
--
---------------------------------------------------------------------------------------------------
*/
SELECT
    YEAR,
    AREAID,
    OCCID,
    ROUND(EARN_AVG,2) AS HOURLY_WAGE,
    ROUND(EARN_AVG,2) * 2080 AS YEARLY_WAGE
FROM
    LIGHTCAST.TULSA_FOR_YOU.DAT_OCC
WHERE
    CLASSID = 1
    AND AREAID_TYPE = 'COUNTY'
    AND YEAR <= YEAR(CURRENT_DATE()) 