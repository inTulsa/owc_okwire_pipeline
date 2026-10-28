/*
---------------------------------------------------------------------------------------------------
--
-- Description:     Builds the job openings fact table: total annual openings by county and
--                   occupation.
--
-- Date:            2026-10-27
--
-- Notes:
-- Source: LIGHTCAST_DATA.CORELMI_US_V3.DAT_OCC (national data), filtered to
-- AREAID_TYPE = 'COUNTY', Oklahoma counties only (LEFT(LPAD(AREAID, 5, '0'), 2) = '40'), and
-- CLASSID <> 4 (excludes self-employed, which have no reported openings). NUM_OPENINGS
-- sums REPLACEMENTS, i.e. openings from worker turnover (does not include growth openings).
--
---------------------------------------------------------------------------------------------------
*/

SELECT
    YEAR,
    AREAID,
    OCCID,
    ROUND(SUM(REPLACEMENTS + GROWTH), 0) AS OPENINGS
FROM
    LIGHTCAST_DATA.CORELMI_US_V3.DAT_OCC
WHERE
    CLASSID <> 4
    AND AREAID_TYPE = 'COUNTY'
    AND LEFT(LPAD(AREAID, 5, '0'), 2) = '40'
    AND YEAR <= YEAR(CURRENT_DATE()) 
GROUP BY
    YEAR,
    AREAID,
    OCCID
