/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the job openings fact table: total annual openings by county and
--                   occupation.
--
-- Date:            2025-12-02
--
-- Notes:
-- Source: LIGHTCAST.TULSA_FOR_YOU.DAT_OCC, filtered to AREAID_TYPE = 'COUNTY' and
-- CLASSID <> 4 (excludes self-employed, which have no reported openings). NUM_OPENINGS
-- sums REPLACEMENTS, i.e. openings from worker turnover (does not include growth openings).
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